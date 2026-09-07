// Copyright Epic Games, Inc. All Rights Reserved.
import { SignallingServer, redactSensitiveLogValue } from '@epicgames-ps/lib-pixelstreamingsignalling-ue5.8';

/* eslint-disable @typescript-eslint/no-unsafe-call,
                  @typescript-eslint/no-unsafe-member-access */

// These are live transports or callbacks, not serializable public configuration.
const INTERNAL_CONFIG_FIELDS = new Set([
    'httpServer',
    'httpsServer',
    'streamerWsOptions',
    'playerWsOptions',
    'sfuWsOptions',
    'authorizeStreamerId',
    'peerOptionsProvider'
]);

export default function (signallingServer: SignallingServer) {
    const operations = {
        GET
    };

    function GET(req: any, res: any, _next: any) {
        res.status(200).json({
            config: redactSensitiveLogValue(
                Object.fromEntries(
                    Object.entries(signallingServer.config).filter(
                        ([key]) => !INTERNAL_CONFIG_FIELDS.has(key)
                    )
                )
            ),
            protocolConfig: redactSensitiveLogValue(signallingServer.protocolConfig)
        });
    }

    GET.apiDoc = {
        summary: 'Returns the current configuration of the server.',
        operationId: 'getConfig',
        responses: {
            200: {
                description: 'The current configuration of the server.',
                content: {
                    'application/json': {
                        schema: {
                            type: 'object',
                            properties: {
                                config: {
                                    type: 'object'
                                },
                                protocolConfig: {
                                    type: 'object'
                                }
                            }
                        }
                    }
                }
            }
        }
    };

    return operations;
}
