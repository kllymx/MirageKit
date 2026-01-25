//
//  MirageClientService+WindowList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window list request helper.
//

import Foundation

@MainActor
extension MirageClientService {
    /// Request updated window list from host.
    public func requestWindowList() async throws {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }

        let message = ControlMessage(type: .windowListRequest)
        connection.send(content: message.serialize(), completion: .idempotent)
    }
}
