// Copyright Epic Games, Inc. All Rights Reserved.
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);
export const ARTIFACT_PROCESS_TIMEOUT_MS = 120_000;

/** Kill a stalled owned artifact process before allowing its queue to retry. */
export async function execArtifactFile(
    executable: string,
    args: string[],
    options: { env?: NodeJS.ProcessEnv } = {},
    timeoutMs = ARTIFACT_PROCESS_TIMEOUT_MS
): Promise<{ stdout: string; stderr: string }> {
    const result = await execFileAsync(executable, args, {
        ...options,
        encoding: 'utf8',
        windowsHide: true,
        timeout: timeoutMs,
        killSignal: 'SIGKILL'
    });
    return { stdout: result.stdout, stderr: result.stderr };
}
