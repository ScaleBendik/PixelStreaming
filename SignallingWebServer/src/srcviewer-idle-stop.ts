// src/viewer-idle-stop.ts
import { EC2Client, StopInstancesCommand } from "@aws-sdk/client-ec2";
import type { Server as HttpServer } from "http";
import type { Socket, AddressInfo } from "net";

export interface ViewerIdleOptions {
  /** Stop after this long once the last viewer disconnects (ms). Default: env GRACE_MS or 10 min */
  graceMs?: number;
  /** Retry interval for wiring up (ms). Default: 500 */
  attachIntervalMs?: number;
  /** Give up after this many ms. 0 = retry forever. Default: 0 */
  attachTimeoutMs?: number;
  /** Player HTTP server port (e.g., 80). If set, HTTP upgrade hook filters by this port. */
  playerPort?: number;
  /** Stop if nobody ever connects within this long window (ms). Default: env NO_VIEWER_GRACE_MS or 60 min */
  firstViewerGraceMs?: number;
  /** Optional delay before starting the "no-first-viewer" timer (ms). Default: env NO_VIEWER_DELAY_MS or 0 */
  firstViewerDelayMs?: number;
  /** Optional custom logger */
  logger?: (msg: string) => void;
}

/**
 * Server-only idle shutdown for Pixel Streaming:
 * - Counts viewer WS connections; when the count hits 0, schedules a stop after `graceMs`.
 * - Also stops if **no viewer ever connects** within `firstViewerGraceMs` (longer window).
 */
export function wireViewerIdleStop(root: any, opts: ViewerIdleOptions = {}) {
  const log = opts.logger ?? ((m: string) => console.log(m));
  const GRACE_MS = opts.graceMs ?? Number(process.env.GRACE_MS ?? 10 * 60_000);
  const SCAN_EVERY = opts.attachIntervalMs ?? 500;
  const TIMEOUT = opts.attachTimeoutMs ?? 0; // 0 = never stop retrying
  const PLAYER_PORT = opts.playerPort;
  const FIRST_VIEWER_GRACE_MS =
    opts.firstViewerGraceMs ?? Number(process.env.NO_VIEWER_GRACE_MS ?? 60 * 60_000);
  const FIRST_VIEWER_DELAY_MS =
    opts.firstViewerDelayMs ?? Number(process.env.NO_VIEWER_DELAY_MS ?? 0);

  let viewerCount = 0;
  let zeroViewersTimer: NodeJS.Timeout | null = null;
  let firstViewerTimer: NodeJS.Timeout | null = null;

  const cancelZeroTimer = () => {
    if (zeroViewersTimer) {
      clearTimeout(zeroViewersTimer);
      zeroViewersTimer = null;
    }
  };
  const cancelFirstViewerTimer = () => {
    if (firstViewerTimer) {
      clearTimeout(firstViewerTimer);
      firstViewerTimer = null;
      log("[idle] first-viewer timer cancelled (a viewer connected)");
    }
  };

  const onConnect = () => {
    viewerCount += 1;
    cancelZeroTimer();
    cancelFirstViewerTimer();
    log(`[idle] viewer connected (count=${viewerCount})`);
  };

  const onDisconnect = () => {
    viewerCount = Math.max(0, viewerCount - 1);
    log(`[idle] viewer disconnected (count=${viewerCount})`);
    if (viewerCount === 0) {
      if (zeroViewersTimer) clearTimeout(zeroViewersTimer);
      zeroViewersTimer = setTimeout(stopSelf, GRACE_MS);
      log(`[idle] no viewers → stopping in ${GRACE_MS} ms`);
    }
  };

  function isWssCandidate(x: any): boolean {
    // ws.WebSocketServer has .on() and a Set of .clients
    return !!(x && typeof x === "object" && typeof x.on === "function" && x.clients && typeof x.clients.size === "number");
  }
  function isHttpServer(x: any): x is HttpServer {
    return !!(x && typeof x === "object" && typeof x.on === "function" && typeof x.address === "function" && typeof x.listen === "function");
  }
  function deepFind<T>(rootObj: any, pred: (o: any) => boolean, maxDepth = 12): { obj: T; path: string } | null {
    const seen = new WeakSet<object>();
    type Item = { o: any; p: string; d: number };
    const q: Item[] = [{ o: rootObj, p: "root", d: 0 }];
    while (q.length) {
      const { o, p, d } = q.shift()!;
      if (!o || typeof o !== "object") continue;
      if (seen.has(o)) continue;
      seen.add(o);
      if (pred(o)) return { obj: o as T, path: p };
      if (d >= maxDepth) continue;
      for (const k of Object.keys(o)) {
        try {
          const child = (o as any)[k];
          if (!child || typeof child === "function") continue;
          q.push({ o: child, p: `${p}.${k}`, d: d + 1 });
        } catch { /* ignore getters */ }
      }
    }
    return null;
  }

  function attachHttpUpgrade(http: HttpServer): boolean {
    http.on("upgrade", (req, socket /* Duplex */) => {
      // req.socket is a net.Socket (has localPort)
      const localPort =
        (req.socket as Socket).localPort ??
        ((http.address() as AddressInfo | null)?.port ?? undefined);
      if (PLAYER_PORT && localPort !== PLAYER_PORT) return; // ignore non-player upgrades
      onConnect();
      socket.on("close", onDisconnect);
      socket.on("error", onDisconnect);
    });

    const bound = (http.address() as AddressInfo | null)?.port;
    log(
      `[idle] attached to HTTP upgrade listener (server port=${bound ?? "unknown"}${
        PLAYER_PORT ? `, filter=${PLAYER_PORT}` : ""
      })`
    );
    return true;
  }

  function tryAttachOnce(): boolean {
    let attachedSomething = false;

    // 1) Best-effort: attach to "server events" if they exist (often no-ops on PS 2.0)
    if (typeof root?.on === "function") {
      try { root.on("playerConnected", onConnect); root.on("playerDisconnected", onDisconnect); attachedSomething = true; } catch {}
      try { root.on("wsPlayerConnected", onConnect); root.on("wsPlayerDisconnected", onDisconnect); attachedSomething = true; } catch {}
      if (attachedSomething) log("[idle] attached to signalling server events (may be inactive on PS 2.0)");
    }

    // 2) Explicit/common paths for Players WSS (fast path)
    const explicit = root?.playerServer?.wss ?? root?.playersWss ?? root?.wssPlayers ?? root?.wss;
    if (isWssCandidate(explicit)) {
      explicit.on("connection", (ws: any) => {
        onConnect();
        ws.on("close", onDisconnect);
        ws.on("error", onDisconnect);
      });
      log("[idle] attached to player WebSocket server (explicit path)");
      return true;
    }

    // 3) Deep-scan for a WebSocketServer anywhere
    const foundWss = deepFind<any>(root, isWssCandidate, 12);
    if (foundWss) {
      const { obj: wss, path } = foundWss;
      wss.on("connection", (ws: any) => {
        onConnect();
        ws.on("close", onDisconnect);
        ws.on("error", onDisconnect);
      });
      log(`[idle] attached to player WebSocket server at: ${path}`);
      return true;
    }

    // 4) Fallback: hook HTTP server 'upgrade' (counts WS connects regardless of where WSS lives)
    const foundHttp = deepFind<HttpServer>(root, isHttpServer, 12);
    if (foundHttp) {
      attachHttpUpgrade(foundHttp.obj);
      return true;
    }

    return attachedSomething;
  }

  // Periodically try to attach until we succeed (or optional timeout)
  const started = Date.now();
  const iv = setInterval(() => {
    if (tryAttachOnce()) {
      clearInterval(iv);
      log("[idle] viewer-idle-stop wired.");

      // Start the "no-first-viewer" timer now that the server is ready to accept players
      if (FIRST_VIEWER_GRACE_MS > 0) {
        const startFirstViewerTimer = () => {
          if (viewerCount > 0) return; // someone already connected
          firstViewerTimer = setTimeout(() => {
            // double-check before stopping in case someone connected just now
            if (viewerCount === 0) {
              log(`[idle] no viewer connected within ${FIRST_VIEWER_GRACE_MS} ms → stopping`);
              stopSelf();
            }
          }, FIRST_VIEWER_GRACE_MS);
          log(`[idle] first-viewer timer started → will stop in ${FIRST_VIEWER_GRACE_MS} ms if nobody connects`);
        };
        if (FIRST_VIEWER_DELAY_MS > 0) {
          setTimeout(startFirstViewerTimer, FIRST_VIEWER_DELAY_MS);
          log(`[idle] will start first-viewer timer after ${FIRST_VIEWER_DELAY_MS} ms`);
        } else {
          startFirstViewerTimer();
        }
      }
      return;
    }
    if (TIMEOUT > 0 && Date.now() - started > TIMEOUT) {
      clearInterval(iv);
      log("[idle] WARN: could not find player connections to hook (continuing without idle stop)");
    }
  }, SCAN_EVERY);

  async function stopSelf() {
    // Abort if someone connected during the grace window
    if (viewerCount > 0) {
      log("[idle] stopSelf aborted: a viewer is connected");
      return;
    }
    zeroViewersTimer = null;
  
    try {
      // IMDSv2 (on EC2). Will fail locally — expected during dev.
      const token = await fetch("http://169.254.169.254/latest/api/token", {
        method: "PUT",
        headers: { "X-aws-ec2-metadata-token-ttl-seconds": "21600" },
      }).then((r) => r.text());
  
      const [instanceId, region] = await Promise.all([
        fetch("http://169.254.169.254/latest/meta-data/instance-id", {
          headers: { "X-aws-ec2-metadata-token": token }
        }).then((r) => r.text()),
        fetch("http://169.254.169.254/latest/meta-data/placement/region", {
          headers: { "X-aws-ec2-metadata-token": token }
        }).then((r) => r.text()),
      ]);
  
      await new EC2Client({ region }).send(new StopInstancesCommand({ InstanceIds: [instanceId] }));
      log(`[idle] StopInstances requested for ${instanceId} (${region})`);
    } catch (e: any) {
      log(`[idle] stopSelf failed (likely not on EC2): ${e?.message ?? e}`);
    }
  }
}

