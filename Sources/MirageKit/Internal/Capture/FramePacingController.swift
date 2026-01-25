//
//  FramePacingController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//

import Foundation

#if os(macOS)
import CoreVideo

/// Frame pacing controller for consistent frame timing
actor FramePacingController {
    private let targetFrameInterval: TimeInterval
    private var lastFrameTime: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedCount: UInt64 = 0

    private var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    init(targetFPS: Int) {
        self.targetFrameInterval = 1.0 / Double(targetFPS)
    }

    /// Check if a frame should be captured based on timing
    func shouldCaptureFrame() -> Bool {
        let now = mach_absolute_time()

        if lastFrameTime == 0 {
            lastFrameTime = now
            frameCount += 1
            return true
        }

        let elapsedNanos = (now - lastFrameTime) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0

        if elapsedSeconds >= targetFrameInterval * 0.95 {
            lastFrameTime = now
            frameCount += 1
            return true
        }

        return false
    }

    /// Mark a frame as dropped
    func markFrameDropped() {
        droppedCount += 1
    }

    /// Get statistics
    func getStatistics() -> (frames: UInt64, dropped: UInt64) {
        (frameCount, droppedCount)
    }
}

#endif
