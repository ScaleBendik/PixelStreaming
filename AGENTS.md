# ServerManager PixelStreaming Agent Instructions

This repo is part of the larger ServerManager workspace.

Before planning, reviewing, editing, debugging, or running commands in this repo,
if `../docs/ai-context/00-index.md` exists:

1. Read `../docs/ai-context/00-index.md`.
2. Read `../docs/ai-context/pixelstreaming.md`.
3. Read `../docs/ai-context/local-dev.md` for command verification.
4. Read `../docs/ai-context/conventions-and-traps.md`.

Also read `../docs/ai-context/release-update-flow.md` and
`../docs/ai-context/cross-system-flows.md` when touching runtime artifacts,
connect-ticket validation, Wilbur, instance-agent behavior, viewer idle/recycle,
startup scripts, artifact upload, or release/update behavior.

The canonical active backlog is
`../scaleworld-server-manager-web/MASTER_BACKLOG.md`. Check it before making
roadmap, rollout, release, or priority claims. If durable PixelStreaming runtime
behavior, commands, config, deployment assumptions, cross-system contracts, or
backlog state changes, update the relevant `../docs/ai-context/` docs and the
canonical backlog when appropriate.

Do not run operational scripts that stop/recycle instances, mutate EC2 tags,
activate runtimes, or upload artifacts unless that is the explicit task.

