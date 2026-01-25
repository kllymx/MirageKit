//
//  MessageTypes+Keyframe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Message type definitions.
//

import Foundation

// MARK: - Keyframe Messages

struct KeyframeRequestMessage: Codable {
    let streamID: StreamID
}
