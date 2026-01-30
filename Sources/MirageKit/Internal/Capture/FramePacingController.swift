//
//  FramePacingController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import Foundation

#if os(macOS)

/// Frame pacing controller for consistent frame timing.
final class FramePacingController: @unchecked Sendable {
    private let lock = NSLock()
    private var targetFrameInterval: TimeInterval
    private var nextEmitTime: CFAbsoluteTime = 0
    private var lastEmitTime: CFAbsoluteTime = 0
    private var frameCount: UInt64 = 0
    private var droppedCount: UInt64 = 0

    init(targetFPS: Int) {
        let clamped = max(1, targetFPS)
        self.targetFrameInterval = 1.0 / Double(clamped)
    }

    func updateTargetFPS(_ targetFPS: Int) {
        let clamped = max(1, targetFPS)
        lock.lock()
        targetFrameInterval = 1.0 / Double(clamped)
        nextEmitTime = 0
        lastEmitTime = 0
        frameCount = 0
        droppedCount = 0
        lock.unlock()
    }

    /// Check if a frame should be captured based on timing.
    func shouldCaptureFrame(at time: CFAbsoluteTime) -> Bool {
        lock.lock()
        if nextEmitTime == 0 {
            nextEmitTime = time + targetFrameInterval
            lastEmitTime = time
            frameCount += 1
            lock.unlock()
            return true
        }

        if time < nextEmitTime {
            droppedCount += 1
            lock.unlock()
            return false
        }

        let stallThreshold = targetFrameInterval * 4
        if lastEmitTime > 0, time - lastEmitTime > stallThreshold {
            nextEmitTime = time + targetFrameInterval
            lastEmitTime = time
            frameCount += 1
            lock.unlock()
            return true
        }

        let elapsed = time - nextEmitTime
        let intervals = max(1, Int(elapsed / targetFrameInterval) + 1)
        nextEmitTime += targetFrameInterval * Double(intervals)
        lastEmitTime = time
        frameCount += 1
        lock.unlock()
        return true
    }

    /// Get statistics.
    func getStatistics() -> (frames: UInt64, dropped: UInt64) {
        lock.lock()
        let stats = (frameCount, droppedCount)
        lock.unlock()
        return stats
    }
}

#endif
