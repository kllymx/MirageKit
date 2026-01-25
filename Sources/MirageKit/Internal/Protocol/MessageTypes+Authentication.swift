//
//  MessageTypes+Authentication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Authentication Messages

struct AuthRequestMessage: Codable {
    let deviceID: UUID
    let publicKey: Data
}

struct AuthChallengeMessage: Codable {
    let challenge: Data
}

struct AuthResponseMessage: Codable {
    let signature: Data
}

struct AuthResultMessage: Codable {
    let success: Bool
    let trusted: Bool
    let errorMessage: String?
}
