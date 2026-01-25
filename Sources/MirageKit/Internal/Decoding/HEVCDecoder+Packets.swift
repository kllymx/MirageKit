//
//  HEVCDecoder+Packets.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  HEVC decoder extensions.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

extension FrameReassembler {
    func setFrameHandler(_ handler: @escaping @Sendable (StreamID, Data, Bool, UInt64, CGRect) -> Void) {
        onFrameComplete = handler
    }
    func updateExpectedDimensionToken(_ token: UInt16) {
        expectedDimensionToken = token
        dimensionTokenValidationEnabled = true
        MirageLogger.log(.frameAssembly, "Expected dimension token updated to \(token) for stream \(streamID)")
    }
    func processPacket(_ data: Data, header: FrameHeader) {
        let frameNumber = header.frameNumber
        let isKeyframePacket = header.flags.contains(.keyframe)
        totalPacketsReceived += 1

        // Log stats every 1000 packets
        if totalPacketsReceived - lastStatsLog >= 1000 {
            lastStatsLog = totalPacketsReceived
            MirageLogger.log(.frameAssembly, "STATS: packets=\(totalPacketsReceived), framesDelivered=\(framesDelivered), pending=\(pendingFrames.count), discarded(old=\(packetsDiscardedOld), crc=\(packetsDiscardedCRC), token=\(packetsDiscardedToken), epoch=\(packetsDiscardedEpoch), awaitKeyframe=\(packetsDiscardedAwaitingKeyframe))")
        }

        if header.epoch != currentEpoch {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "epoch mismatch")
            } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                return
            }
        }

        if header.flags.contains(.discontinuity) {
            if isKeyframePacket {
                resetForEpoch(header.epoch, reason: "discontinuity")
            } else {
                packetsDiscardedEpoch += 1
                beginAwaitingKeyframe()
                return
            }
        }

        // Validate dimension token to reject old-dimension frames after resize.
        // Keyframes always update the expected token since they establish new dimensions.
        // P-frames with mismatched tokens are silently discarded.
        if dimensionTokenValidationEnabled {
            if isKeyframePacket {
                // Keyframes update the expected token - they carry new VPS/SPS/PPS
                if header.dimensionToken != expectedDimensionToken {
                    MirageLogger.log(.frameAssembly, "Keyframe updated dimension token from \(expectedDimensionToken) to \(header.dimensionToken)")
                    expectedDimensionToken = header.dimensionToken
                }
            } else if header.dimensionToken != expectedDimensionToken {
                // P-frame with wrong token - silently discard (old dimensions)
                packetsDiscardedToken += 1
                return
            }
        }

        if awaitingKeyframe && !isKeyframePacket {
            packetsDiscardedAwaitingKeyframe += 1
            return
        }

        // Validate CRC32 checksum to detect corrupted packets
        let calculatedCRC = CRC32.calculate(data)
        if calculatedCRC != header.checksum {
            packetsDiscardedCRC += 1
            MirageLogger.log(.frameAssembly, "CRC mismatch for frame \(frameNumber) fragment \(header.fragmentIndex) - discarding (expected \(header.checksum), got \(calculatedCRC))")
            return
        }

        // Skip old P-frames, but NEVER skip keyframe packets.
        // Keyframes are large (400+ packets) and take longer to transmit than small P-frames.
        // P-frames sent after a keyframe may complete before the keyframe finishes.
        // If we skip "old" keyframe packets, recovery becomes impossible.
        let isOldFrame = frameNumber < lastCompletedFrame && lastCompletedFrame - frameNumber < 1000
        if isOldFrame && !isKeyframePacket {
            packetsDiscardedOld += 1
            return
        }

        // Get or create pending frame
        var frame = pendingFrames[frameNumber] ?? PendingFrame(
            fragments: [:],
            totalFragments: header.fragmentCount,
            isKeyframe: isKeyframePacket,
            timestamp: header.timestamp,
            receivedAt: Date(),
            contentRect: header.contentRect
        )

        // Update keyframe flag if this packet has it (in case fragments arrive out of order)
        if isKeyframePacket && !frame.isKeyframe {
            frame.isKeyframe = true
        }

        // NOTE: We intentionally do NOT discard older incomplete keyframes when a newer one starts.
        // During network congestion, multiple keyframes may arrive simultaneously. Discarding
        // partially-complete keyframes (even 70%+) in favor of new ones creates a cascade where
        // ALL keyframes fail. Instead, let each keyframe complete or timeout naturally via
        // cleanupOldFrames(). The timeout-based approach is more robust.

        // Store fragment
        frame.fragments[header.fragmentIndex] = data
        pendingFrames[frameNumber] = frame

        // Log keyframe assembly progress for diagnostics
        if frame.isKeyframe {
            let receivedCount = frame.fragments.count
            let totalCount = Int(frame.totalFragments)
            // Log at key milestones: first packet, 25%, 50%, 75%, and when nearly complete
            if receivedCount == 1 || receivedCount == totalCount / 4 || receivedCount == totalCount / 2 ||
               receivedCount == (totalCount * 3) / 4 || receivedCount == totalCount - 1 {
                MirageLogger.log(.frameAssembly, "Keyframe \(frameNumber): \(receivedCount)/\(totalCount) fragments received")
            }
        }

        // Check if frame is complete
        if frame.fragments.count == Int(frame.totalFragments) {
            completeFrame(frameNumber: frameNumber, frame: frame)
        }

        // Clean up old pending frames
        cleanupOldFrames()
    }
    private func completeFrame(frameNumber: UInt32, frame: PendingFrame) {
        // Reassemble fragments in order
        var completeData = Data()
        for i in 0..<frame.totalFragments {
            if let fragment = frame.fragments[i] {
                completeData.append(fragment)
            } else {
                // Missing fragment, can't complete
                MirageLogger.log(.frameAssembly, "Frame \(frameNumber) incomplete - missing fragment \(i)")
                pendingFrames.removeValue(forKey: frameNumber)
                droppedFrameCount += 1
                return
            }
        }

        // Frame skipping logic: determine if we should deliver this frame
        let shouldDeliver: Bool

        if frame.isKeyframe {
            // Always deliver keyframes unless a newer keyframe was already delivered
            shouldDeliver = frameNumber > lastDeliveredKeyframe || lastDeliveredKeyframe == 0
            if shouldDeliver {
                lastDeliveredKeyframe = frameNumber
            }
        } else {
            // For P-frames: only deliver if newer than last completed frame
            // and after the last keyframe (decoder needs the reference)
            shouldDeliver = frameNumber > lastCompletedFrame && frameNumber > lastDeliveredKeyframe
        }

        if shouldDeliver {
            // Discard any pending frames older than this one
            discardOlderPendingFrames(olderThan: frameNumber)

            lastCompletedFrame = frameNumber
            pendingFrames.removeValue(forKey: frameNumber)

            framesDelivered += 1
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "Delivering keyframe \(frameNumber) (\(completeData.count) bytes)")
                clearAwaitingKeyframe()
            }
            onFrameComplete?(streamID, completeData, frame.isKeyframe, frame.timestamp, frame.contentRect)
        } else {
            // This frame arrived too late - a newer frame was already delivered
            if frame.isKeyframe {
                MirageLogger.log(.frameAssembly, "WARNING: Keyframe \(frameNumber) NOT delivered (lastDeliveredKeyframe=\(lastDeliveredKeyframe))")
            }
            pendingFrames.removeValue(forKey: frameNumber)
            droppedFrameCount += 1
        }
    }
    private func discardOlderPendingFrames(olderThan frameNumber: UInt32) {
        let framesToDiscard = pendingFrames.keys.filter { pendingFrameNumber in
            // Discard P-frames older than the one we're about to deliver
            // Handle wrap-around: if difference is huge, it's probably wrap-around
            guard pendingFrameNumber < frameNumber && frameNumber - pendingFrameNumber < 1000 else {
                return false
            }
            // NEVER discard pending keyframes - they're critical for decoder recovery
            // Keyframes are large (500+ packets) and take longer to arrive than P-frames
            // If we discard an incomplete keyframe, the decoder will be stuck
            if let frame = pendingFrames[pendingFrameNumber], frame.isKeyframe {
                return false
            }
            return true
        }

        for discardFrame in framesToDiscard {
            if pendingFrames[discardFrame] != nil {
                droppedFrameCount += 1
            }
            pendingFrames.removeValue(forKey: discardFrame)
        }
    }
    private func resetForEpoch(_ epoch: UInt16, reason: String) {
        currentEpoch = epoch
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        clearAwaitingKeyframe()
        packetsDiscardedAwaitingKeyframe = 0
        MirageLogger.log(.frameAssembly, "Epoch \(epoch) reset (\(reason)) for stream \(streamID)")
    }
    private func cleanupOldFrames() {
        let now = Date()
        // P-frame timeout: 500ms - allows time for UDP packet jitter without dropping frames
        let pFrameTimeout: TimeInterval = 0.5
        // Keyframes are 600-900 packets and critical for recovery
        // They need much more time to complete than small P-frames

        var timedOutCount: UInt64 = 0
        pendingFrames = pendingFrames.filter { frameNumber, frame in
            let timeout = frame.isKeyframe ? keyframeTimeout : pFrameTimeout
            let shouldKeep = now.timeIntervalSince(frame.receivedAt) < timeout
            if !shouldKeep {
                // Log timeout with fragment completion info for debugging
                let receivedCount = frame.fragments.count
                let totalCount = frame.totalFragments
                let isKeyframe = frame.isKeyframe
                MirageLogger.log(.frameAssembly, "Frame \(frameNumber) timed out: \(receivedCount)/\(totalCount) fragments\(isKeyframe ? " (KEYFRAME)" : "")")
                timedOutCount += 1
            }
            return shouldKeep
        }
        droppedFrameCount += timedOutCount
    }
    func shouldRequestKeyframe() -> Bool {
        let incompleteCount = pendingFrames.count
        return incompleteCount > 5
    }
    func getDroppedFrameCount() -> UInt64 {
        droppedFrameCount
    }
    func enterKeyframeOnlyMode() {
        beginAwaitingKeyframe()
        pendingFrames = pendingFrames.filter { $0.value.isKeyframe }
        MirageLogger.log(.frameAssembly, "Entering keyframe-only mode for stream \(streamID)")
    }
    func awaitingKeyframeDuration(now: CFAbsoluteTime) -> CFAbsoluteTime? {
        guard awaitingKeyframe, awaitingKeyframeSince > 0 else { return nil }
        return now - awaitingKeyframeSince
    }
    func keyframeTimeoutSeconds() -> CFAbsoluteTime {
        keyframeTimeout
    }
    func reset() {
        pendingFrames.removeAll()
        lastCompletedFrame = 0
        lastDeliveredKeyframe = 0
        clearAwaitingKeyframe()
        droppedFrameCount = 0
        MirageLogger.log(.frameAssembly, "Reassembler reset for stream \(streamID)")
    }
    private func beginAwaitingKeyframe() {
        if !awaitingKeyframe || awaitingKeyframeSince == 0 {
            awaitingKeyframe = true
            awaitingKeyframeSince = CFAbsoluteTimeGetCurrent()
        }
    }
    private func clearAwaitingKeyframe() {
        awaitingKeyframe = false
        awaitingKeyframeSince = 0
    }
}

