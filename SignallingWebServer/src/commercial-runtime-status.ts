// Copyright Epic Games, Inc. All Rights Reserved.
import type { ConnectTicketRuntimeGate } from './connect-ticket-runtime-state';
import type { RuntimeStatusPublisher, RuntimeStatusUpdate } from './runtime-status';

export function createCommercialRuntimeStatusPublisher(
    baseRuntimeStatusPublisher: RuntimeStatusPublisher,
    connectTicketRuntimeGate: ConnectTicketRuntimeGate,
    instanceAgentClient: { recordRuntimeStatus(update: RuntimeStatusUpdate): void } | null
): RuntimeStatusPublisher {
    let externallyPublishedCommercialReadinessBlock = false;
    let observedRuntimeStatus: string | null = null;
    let commercialReadinessReleaseTimer: NodeJS.Timeout | null = null;
    let pendingCommercialReadyUpdate: RuntimeStatusUpdate | null = null;
    const cancelCommercialReadinessRelease = (): void => {
        pendingCommercialReadyUpdate = null;
        if (commercialReadinessReleaseTimer) {
            clearTimeout(commercialReadinessReleaseTimer);
            commercialReadinessReleaseTimer = null;
        }
    };
    const scheduleCommercialReadinessRelease = (
        readyNotBeforeEpochSeconds: number,
        update: RuntimeStatusUpdate
    ): void => {
        pendingCommercialReadyUpdate = { ...update, heartbeatOnly: false };
        if (commercialReadinessReleaseTimer) {
            return;
        }

        const delayMs = Math.max(25, (readyNotBeforeEpochSeconds + 1) * 1000 - Date.now());
        commercialReadinessReleaseTimer = setTimeout(() => {
            commercialReadinessReleaseTimer = null;
            const readyUpdate = pendingCommercialReadyUpdate;
            pendingCommercialReadyUpdate = null;
            if (readyUpdate) {
                void publisher.publish(readyUpdate);
            }
        }, delayMs);
        commercialReadinessReleaseTimer.unref();
    };
    const publisher: RuntimeStatusPublisher = {
        async publish(update) {
            const normalizedStatus = update.status.trim().toLowerCase();
            if (
                update.heartbeatOnly === true &&
                observedRuntimeStatus &&
                normalizedStatus !== observedRuntimeStatus
            ) {
                return baseRuntimeStatusPublisher.publish(update);
            }
            if (update.heartbeatOnly !== true) {
                observedRuntimeStatus = normalizedStatus;
                if (normalizedStatus !== 'ready') {
                    // A real regression must cancel the replacement's pending Ready release.
                    cancelCommercialReadinessRelease();
                }
            }

            instanceAgentClient?.recordRuntimeStatus(update);
            const commercialReadinessBlockReason =
                connectTicketRuntimeGate.getReconnectGraceEvidenceJournalBlockReason() ??
                (connectTicketRuntimeGate.isCommercialRecoveryRequired()
                    ? 'commercial session recovery is incomplete'
                    : null);
            if (normalizedStatus === 'ready' && commercialReadinessBlockReason) {
                const readyNotBeforeEpochSeconds =
                    connectTicketRuntimeGate.getCommercialRecoveryReadyNotBeforeEpochSeconds();
                if (readyNotBeforeEpochSeconds !== null) {
                    scheduleCommercialReadinessRelease(readyNotBeforeEpochSeconds, update);
                }
                const wasAlreadyBlocked = externallyPublishedCommercialReadinessBlock;
                externallyPublishedCommercialReadinessBlock = true;
                return baseRuntimeStatusPublisher.publish({
                    ...update,
                    status: 'resetting',
                    reason: 'commercial_session_recovery_required',
                    heartbeatOnly: wasAlreadyBlocked ? update.heartbeatOnly : false
                });
            }

            const forceReadyTransition =
                normalizedStatus === 'ready' && externallyPublishedCommercialReadinessBlock;
            if (normalizedStatus === 'ready') {
                externallyPublishedCommercialReadinessBlock = false;
                cancelCommercialReadinessRelease();
            }
            return baseRuntimeStatusPublisher.publish(
                forceReadyTransition ? { ...update, heartbeatOnly: false } : update
            );
        }
    };
    return publisher;
}
