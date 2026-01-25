//
//  MessageTypes+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Session State Messages (Headless Mac Support)

/// Host session state - indicates whether the Mac is accessible for streaming
public enum HostSessionState: String, Codable, Sendable {
    /// Screen is unlocked, ready for normal streaming
    case active
    /// Screen is locked (user logged in but screen locked, password only needed)
    case screenLocked
    /// At login window (no user session, username + password needed)
    case loginScreen
    /// Mac is asleep (needs wake before unlock)
    case sleeping

    /// Whether credentials are required to reach active state
    public var requiresUnlock: Bool {
        switch self {
        case .active: return false
        case .screenLocked, .loginScreen, .sleeping: return true
        }
    }

    /// Whether username is needed in addition to password
    public var requiresUsername: Bool {
        switch self {
        case .loginScreen: return true
        case .active, .screenLocked, .sleeping: return false
        }
    }
}

/// Session state update sent from host to client
/// Sent immediately after connection and whenever state changes
struct SessionStateUpdateMessage: Codable {
    /// Current session state
    let state: HostSessionState
    /// Session token for this state (prevents replay attacks)
    let sessionToken: String
    /// Whether username is needed for unlock
    let requiresUsername: Bool
    /// Timestamp of this update
    let timestamp: Date
}

/// Unlock request sent from client to host
struct UnlockRequestMessage: Codable {
    /// Session token from SessionStateUpdateMessage (must match current)
    let sessionToken: String
    /// Username (required for loginScreen state, ignored otherwise)
    let username: String?
    /// Password for unlock
    let password: String
}

/// Unlock response sent from host to client
struct UnlockResponseMessage: Codable {
    /// Whether unlock was successful
    let success: Bool
    /// New session state after attempt
    let newState: HostSessionState
    /// New session token (if state changed)
    let newSessionToken: String?
    /// Error details if failed
    let error: UnlockError?
    /// Whether client can retry with same token
    let canRetry: Bool
    /// Number of attempts remaining before lockout
    let retriesRemaining: Int?
    /// Seconds to wait before next attempt (rate limiting)
    let retryAfterSeconds: Int?
}

/// Unlock error details
struct UnlockError: Codable {
    let code: UnlockErrorCode
    let message: String
}

/// Error codes for unlock failures
enum UnlockErrorCode: String, Codable {
    /// Wrong username or password
    case invalidCredentials
    /// Too many failed attempts
    case rateLimited
    /// Session token expired or invalid
    case sessionExpired
    /// Host is not in a locked state
    case notLocked
    /// Remote unlock is disabled on host
    case notSupported
    /// Client not authorized for unlock
    case notAuthorized
    /// Unlock operation timed out
    case timeout
    /// Internal error on host
    case internalError
}
