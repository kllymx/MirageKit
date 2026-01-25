//
//  MessageTypes+Input.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation
import CoreGraphics

// MARK: - Input Messages

struct InputEventMessage: Codable {
    let streamID: StreamID
    let event: MirageInputEvent
}
