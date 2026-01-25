//
//  MessageTypes+LoginDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation
import CoreGraphics

// MARK: - Login Display Streaming

/// Sent when host starts streaming the login/lock screen to client
/// Client should prepare to receive frames marked with .loginDisplay flag
struct LoginDisplayReadyMessage: Codable {
    /// Stream ID for the login display stream
    let streamID: UInt32
    /// Resolution of the login display
    let width: Int
    let height: Int
    /// Current session state (screenLocked, loginScreen, etc.)
    let sessionState: HostSessionState
    /// Whether username is needed (true for loginScreen, false for screenLocked)
    let requiresUsername: Bool
    /// Dimension token for rejecting old-dimension P-frames after resize.
    /// Client should update its reassembler with this token.
    var dimensionToken: UInt16? = nil
}

/// Sent when login display stream stops (user logged in successfully)
/// Client should transition to normal window selection mode
struct LoginDisplayStoppedMessage: Codable {
    /// The stream ID that was stopped
    let streamID: UInt32
    /// New session state (should be .active)
    let newState: HostSessionState
}
