//
//  MirageHostService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Control message receiving loop.
//

import Foundation
import Network

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Continuously receive and handle control messages from a client.
    func startReceivingFromClient(connection: NWConnection, client: MirageConnectedClient) {
        var receiveBuffer = Data()
        let bufferLock = NSLock()
        let connectionID = ObjectIdentifier(connection)

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }

                bufferLock.lock()
                if let data, !data.isEmpty {
                    receiveBuffer.append(data)
                }

                var messages: [(message: ControlMessage, isInput: Bool)] = []
                while let (message, consumed) = ControlMessage.deserialize(from: receiveBuffer) {
                    receiveBuffer.removeFirst(consumed)
                    messages.append((message, message.type == .inputEvent))
                }
                bufferLock.unlock()

                for (message, isInput) in messages where isInput {
                    self.inputQueue.async {
                        self.handleInputEventFast(message, from: client)
                    }
                }

                let nonInputMessages = messages.filter { !$0.isInput }.map { $0.message }
                if !nonInputMessages.isEmpty || error != nil || isComplete {
                    Task { @MainActor [weak self] in
                        guard let self else { return }

                        if !nonInputMessages.isEmpty {
                            self.clientFirstErrorTime.removeValue(forKey: connectionID)
                        }

                        for message in nonInputMessages {
                            await self.handleClientMessage(message, from: client, connection: connection)
                        }

                        if let error {
                            let isFatalError = self.isFatalConnectionError(error)

                            if isFatalError {
                                MirageLogger.error(.host, "Client \(client.name) fatal connection error - disconnecting: \(error)")
                                self.clientFirstErrorTime.removeValue(forKey: connectionID)
                                await self.disconnectClient(client)
                                return
                            }

                            let now = CFAbsoluteTimeGetCurrent()
                            if let firstErrorTime = self.clientFirstErrorTime[connectionID] {
                                let errorDuration = now - firstErrorTime
                                if errorDuration >= self.clientErrorTimeoutSeconds {
                                    MirageLogger.error(.host, "Client \(client.name) errors persisted for \(Int(errorDuration))s - disconnecting")
                                    self.clientFirstErrorTime.removeValue(forKey: connectionID)
                                    await self.disconnectClient(client)
                                    return
                                }
                                MirageLogger.host("Client \(client.name) error (persisting for \(Int(errorDuration))s): \(error)")
                            } else {
                                self.clientFirstErrorTime[connectionID] = now
                                MirageLogger.host("Client \(client.name) transient error, will disconnect after \(Int(self.clientErrorTimeoutSeconds))s if not recovered: \(error)")
                            }
                            receiveNext()
                            return
                        }

                        if isComplete {
                            MirageLogger.host("Client disconnected")
                            self.clientFirstErrorTime.removeValue(forKey: connectionID)
                            await self.disconnectClient(client)
                            return
                        }

                        receiveNext()
                    }
                } else {
                    receiveNext()
                }
            }
        }

        receiveNext()
    }
}
#endif
