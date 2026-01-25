//
//  MessageTypes+Error.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Error Messages

struct ErrorMessage: Codable {
    let code: ErrorCode
    let message: String
    let streamID: StreamID?

    enum ErrorCode: String, Codable {
        case unknown
        case invalidMessage
        case streamNotFound
        case windowNotFound
        case encodingError
        case decodingError
        case networkError
        case authRequired
        case permissionDenied
    }
}
