//
//  MirageDirectTouchInputMode.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Direct touch behavior options for iPad and visionOS clients.
//

import Foundation

/// Determines how direct screen touches are translated into host input.
public enum MirageDirectTouchInputMode: String, CaseIterable, Codable, Sendable {
    /// Direct touches move/click/drag the pointer.
    case normal

    /// Direct touches move a virtual cursor (trackpad-style).
    case dragCursor

    /// Direct touches only generate smooth native scroll events.
    case exclusive

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .dragCursor: "Drag Cursor"
        case .exclusive: "Exclusive (Scroll Only)"
        }
    }
}
