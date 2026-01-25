//
//  HEVCDecoder+Handlers.swift
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

extension HEVCDecoder {
    func setErrorThresholdHandler(_ handler: @escaping @Sendable () -> Void) {
        // Wrap the handler to also block input when errors exceed threshold
        let wrappedHandler: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                await self.onInputBlockingChanged?(true)
            }
            handler()
        }
        let inputUnblockHandler: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                await self.onInputBlockingChanged?(false)
            }
        }
        errorTracker = DecodeErrorTracker(
            maxErrors: maxConsecutiveErrors,
            onThresholdReached: wrappedHandler,
            onRecovery: inputUnblockHandler
        )
    }
    func setDimensionChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        onDimensionChange = handler
    }
    func setInputBlockingHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        onInputBlockingChanged = handler
    }
    func getAverageDecodeTimeMs() -> Double {
        performanceTracker.averageMs()
    }
    func getTotalDecodeErrors() -> UInt64 {
        errorTracker?.totalErrorsSnapshot() ?? 0
    }
    func prepareForDimensionChange(expectedWidth: Int? = nil, expectedHeight: Int? = nil) {
        awaitingDimensionChange = true
        dimensionChangeStartTime = CFAbsoluteTimeGetCurrent()
        if let w = expectedWidth, let h = expectedHeight {
            expectedDimensions = (w, h)
        } else {
            expectedDimensions = nil
        }
        MirageLogger.decoder("Dimension change expected - discarding P-frames until keyframe")
        // Block input while awaiting keyframe - user can't see what they're clicking
        onInputBlockingChanged?(true)
    }
    func clearPendingState() {
        let wasBlocking = awaitingDimensionChange
        if awaitingDimensionChange {
            MirageLogger.decoder("Clearing stuck awaitingDimensionChange state for recovery")
            awaitingDimensionChange = false
            expectedDimensions = nil
        }
        // Reset error tracking to give fresh keyframe a clean slate
        errorTracker?.recordSuccess()
        // Unblock input if we were blocking
        if wasBlocking {
            onInputBlockingChanged?(false)
        }
    }
}

