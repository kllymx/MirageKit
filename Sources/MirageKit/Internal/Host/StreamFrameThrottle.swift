//
//  StreamFrameThrottle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/26/26.
//
//  Drops captured frames when capture cadence exceeds the encoder target.
//

import CoreMedia
import Foundation

#if os(macOS)

final class StreamFrameThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var minInterval: CMTime = .invalid
    private var nextAcceptTime: CMTime = .invalid
    private var lastAcceptedTime: CMTime = .invalid
    private var jitterAllowance: CMTime = .invalid
    private let stallResetIntervals: Int32 = 4
    private let statsInterval = CMTime(seconds: 1, preferredTimescale: 600)
    private var targetFrameRate: Int = 0
    private var captureFrameRate: Int = 0
    private var acceptedCount = 0
    private var droppedCount = 0
    private var lastStatsTime: CMTime = .invalid

    func configure(targetFrameRate: Int, captureFrameRate: Int, isPaced: Bool = false) {
        let shouldLog = MirageLogger.isEnabled(.metrics)
        lock.lock()
        let clampedTarget = max(1, targetFrameRate)
        self.targetFrameRate = clampedTarget
        self.captureFrameRate = captureFrameRate
        // When the capture pipeline is already paced to the target FPS,
        // a second throttle here just double-drops frames and lowers cadence.
        if !isPaced, captureFrameRate > clampedTarget {
            isEnabled = true
            minInterval = CMTime(value: 1, timescale: CMTimeScale(clampedTarget))
            jitterAllowance = CMTimeMultiplyByFloat64(minInterval, multiplier: 0.15)
        } else {
            isEnabled = false
            minInterval = .invalid
            jitterAllowance = .invalid
        }
        lastAcceptedTime = .invalid
        nextAcceptTime = .invalid
        acceptedCount = 0
        droppedCount = 0
        lastStatsTime = .invalid
        lock.unlock()
        guard shouldLog else { return }
        let intervalSeconds = minInterval.isValid ? CMTimeGetSeconds(minInterval) : 0
        let jitterSeconds = jitterAllowance.isValid ? CMTimeGetSeconds(jitterAllowance) : 0
        MirageLogger.metrics(
            "Throttle config: enabled=\(isEnabled) target=\(clampedTarget) capture=\(captureFrameRate) interval=\(intervalSeconds)s jitter=\(jitterSeconds)s"
        )
    }

    func shouldDrop(_ frame: CapturedFrame) -> Bool {
        let shouldLog = MirageLogger.isEnabled(.metrics)
        var logMessage: String?
        lock.lock()
        guard isEnabled, minInterval.isValid, frame.presentationTime.isValid else {
            lock.unlock()
            return false
        }
        if !nextAcceptTime.isValid {
            lastAcceptedTime = frame.presentationTime
            nextAcceptTime = CMTimeAdd(frame.presentationTime, minInterval)
            lock.unlock()
            return false
        }
        let gapSinceAccept = lastAcceptedTime.isValid
            ? CMTimeSubtract(frame.presentationTime, lastAcceptedTime)
            : .invalid
        if gapSinceAccept.isValid, CMTimeCompare(gapSinceAccept, .zero) <= 0 {
            lastAcceptedTime = frame.presentationTime
            nextAcceptTime = CMTimeAdd(frame.presentationTime, minInterval)
            lock.unlock()
            return false
        }

        if gapSinceAccept.isValid {
            let stallThreshold = CMTimeMultiply(minInterval, multiplier: stallResetIntervals)
            if CMTimeCompare(gapSinceAccept, stallThreshold) > 0 {
                lastAcceptedTime = frame.presentationTime
                nextAcceptTime = CMTimeAdd(frame.presentationTime, minInterval)
                if shouldLog {
                    let stallSeconds = CMTimeGetSeconds(gapSinceAccept)
                    logMessage = "Throttle stall reset after \(stallSeconds)s gap"
                }
                lock.unlock()
                if let logMessage {
                    MirageLogger.metrics(logMessage)
                }
                return false
            }
        }

        if CMTimeCompare(frame.presentationTime, CMTimeSubtract(nextAcceptTime, jitterAllowance)) < 0 {
            if shouldLog {
                droppedCount += 1
                logMessage = makeStatsLogIfNeeded(at: frame.presentationTime)
            }
            lock.unlock()
            if let logMessage {
                MirageLogger.metrics(logMessage)
            }
            return true
        }
        lastAcceptedTime = frame.presentationTime
        var nextTime = CMTimeAdd(nextAcceptTime, minInterval)
        if CMTimeCompare(nextTime, frame.presentationTime) <= 0 {
            nextTime = CMTimeAdd(frame.presentationTime, minInterval)
        }
        nextAcceptTime = nextTime
        if shouldLog {
            acceptedCount += 1
            logMessage = makeStatsLogIfNeeded(at: frame.presentationTime)
        }
        lock.unlock()
        if let logMessage {
            MirageLogger.metrics(logMessage)
        }
        return false
    }

    func reset() {
        lock.lock()
        lastAcceptedTime = .invalid
        nextAcceptTime = .invalid
        acceptedCount = 0
        droppedCount = 0
        lastStatsTime = .invalid
        lock.unlock()
    }

    private func makeStatsLogIfNeeded(at presentationTime: CMTime) -> String? {
        guard presentationTime.isValid else { return nil }
        if !lastStatsTime.isValid {
            lastStatsTime = presentationTime
            return nil
        }
        let elapsed = CMTimeSubtract(presentationTime, lastStatsTime)
        if !elapsed.isValid || CMTimeCompare(elapsed, .zero) <= 0 {
            lastStatsTime = presentationTime
            acceptedCount = 0
            droppedCount = 0
            return nil
        }
        if CMTimeCompare(elapsed, statsInterval) < 0 {
            return nil
        }
        let elapsedSeconds = CMTimeGetSeconds(elapsed)
        guard elapsedSeconds > 0 else {
            lastStatsTime = presentationTime
            acceptedCount = 0
            droppedCount = 0
            return nil
        }
        let total = acceptedCount + droppedCount
        let dropPercent = total > 0 ? Int((Double(droppedCount) / Double(total)) * 100.0) : 0
        let acceptFps = Int(Double(acceptedCount) / elapsedSeconds)
        let dropFps = Int(Double(droppedCount) / elapsedSeconds)
        let intervalSeconds = minInterval.isValid ? CMTimeGetSeconds(minInterval) : 0
        let jitterSeconds = jitterAllowance.isValid ? CMTimeGetSeconds(jitterAllowance) : 0
        lastStatsTime = presentationTime
        acceptedCount = 0
        droppedCount = 0
        return "Throttle stats: target=\(targetFrameRate) capture=\(captureFrameRate) interval=\(intervalSeconds)s jitter=\(jitterSeconds)s accept=\(acceptFps)fps drop=\(dropFps)fps dropRate=\(dropPercent)%"
    }
}

#endif
