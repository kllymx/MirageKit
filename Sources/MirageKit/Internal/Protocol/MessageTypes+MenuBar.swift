//
//  MessageTypes+MenuBar.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Menu Bar Passthrough Messages

/// Menu bar structure update (Host → Client)
/// Sent when the remote app's menu bar changes or on initial stream start
struct MenuBarUpdateMessage: Codable {
    /// The stream this menu bar applies to
    let streamID: StreamID
    /// The menu bar structure, or nil if extraction failed/unavailable
    let menuBar: MirageMenuBar?
    /// Error message if extraction failed
    let errorMessage: String?

    init(streamID: StreamID, menuBar: MirageMenuBar?, errorMessage: String? = nil) {
        self.streamID = streamID
        self.menuBar = menuBar
        self.errorMessage = errorMessage
    }
}

/// Request to execute a menu action (Client → Host)
struct MenuActionRequestMessage: Codable {
    /// The stream to execute the action on
    let streamID: StreamID
    /// Path to the menu item: [menuIndex, itemIndex, submenuItemIndex, ...]
    let actionPath: [Int]
}

/// Result of menu action execution (Host → Client)
struct MenuActionResultMessage: Codable {
    /// The stream the action was executed on
    let streamID: StreamID
    /// Whether the action was successful
    let success: Bool
    /// Error message if failed
    let errorMessage: String?

    init(streamID: StreamID, success: Bool, errorMessage: String? = nil) {
        self.streamID = streamID
        self.success = success
        self.errorMessage = errorMessage
    }
}
