//
//  ClientStreamSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream session metadata for client-side UI coordination.
//

public struct ClientStreamSession: Identifiable, Sendable {
    public let id: StreamID
    public let window: MirageWindow
    public let quality: MirageQualityPreset

    public init(id: StreamID, window: MirageWindow, quality: MirageQualityPreset) {
        self.id = id
        self.window = window
        self.quality = quality
    }
}
