//
//  MessageTypes+Audio.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/6/26.
//
//  Audio stream control messages.
//

import Foundation

// MARK: - Audio Streaming Messages

package struct AudioStreamStartedMessage: Codable, Equatable, Sendable {
    package let streamID: StreamID
    package let codec: MirageAudioCodec
    package let sampleRate: Int
    package let channelCount: Int

    package init(
        streamID: StreamID,
        codec: MirageAudioCodec,
        sampleRate: Int,
        channelCount: Int
    ) {
        self.streamID = streamID
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

package struct AudioStreamStoppedMessage: Codable, Equatable, Sendable {
    package let streamID: StreamID
    package let reason: AudioStreamStopReason

    package init(streamID: StreamID, reason: AudioStreamStopReason) {
        self.streamID = streamID
        self.reason = reason
    }
}

package enum AudioStreamStopReason: String, Codable, Sendable {
    case clientRequested
    case sourceStopped
    case disabled
    case error
}
