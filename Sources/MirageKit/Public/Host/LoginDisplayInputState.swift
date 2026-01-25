//
//  LoginDisplayInputState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Thread-safe login display input tracking.
//

import Foundation

#if os(macOS)
final class LoginDisplayInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var streamID: StreamID?
    private var bounds: CGRect = .zero
    private var lastCursorPosition: CGPoint = .zero
    private var hasCursorPosition = false

    func update(streamID: StreamID, bounds: CGRect) {
        lock.lock()
        self.streamID = streamID
        self.bounds = bounds
        self.lastCursorPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        self.hasCursorPosition = false
        lock.unlock()
        MirageLogger.host("LoginDisplayInputState registered: streamID=\(streamID), bounds=\(bounds)")
    }

    func clear() {
        lock.lock()
        let previousID = streamID
        streamID = nil
        bounds = .zero
        hasCursorPosition = false
        lock.unlock()
        if let previousID {
            MirageLogger.host("LoginDisplayInputState cleared: was streamID=\(previousID)")
        }
    }

    func getInfo(for streamID: StreamID) -> (bounds: CGRect, lastCursorPosition: CGPoint, hasCursorPosition: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedID = self.streamID, storedID == streamID else {
            return nil
        }
        return (bounds, lastCursorPosition, hasCursorPosition)
    }

    func updateCursorPosition(_ point: CGPoint) {
        lock.lock()
        lastCursorPosition = point
        hasCursorPosition = true
        lock.unlock()
    }
}
#endif
