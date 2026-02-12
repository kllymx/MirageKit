//
//  HEVCDecoder+SubmissionLimiter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  HEVC decoder submission limiter extensions.
//

import Foundation
import MirageKit

extension HEVCDecoder {
    func setDecodeSubmissionLimit(targetFrameRate: Int) {
        let desiredLimit = targetFrameRate >= 120 ? 3 : 2
        guard desiredLimit != decodeSubmissionLimit else { return }
        decodeSubmissionLimit = desiredLimit
        drainDecodeSubmissionWaiters()
        MirageLogger.decoder("Decode submission limit set to \(desiredLimit) (target \(targetFrameRate)fps)")
    }

    func currentDecodeSubmissionLimit() -> Int {
        decodeSubmissionLimit
    }

    func currentInFlightDecodeSubmissions() -> Int {
        inFlightDecodeSubmissions
    }

    func acquireDecodeSubmissionSlot() async {
        if inFlightDecodeSubmissions < decodeSubmissionLimit {
            inFlightDecodeSubmissions += 1
            return
        }
        await withCheckedContinuation { continuation in
            decodeSubmissionWaiters.append(continuation)
        }
    }

    func releaseDecodeSubmissionSlot() {
        if inFlightDecodeSubmissions > 0 {
            inFlightDecodeSubmissions -= 1
        }
        drainDecodeSubmissionWaiters()
    }

    func resetDecodeSubmissionSlots() {
        inFlightDecodeSubmissions = 0
        drainDecodeSubmissionWaiters()
    }

    private func drainDecodeSubmissionWaiters() {
        while inFlightDecodeSubmissions < decodeSubmissionLimit, !decodeSubmissionWaiters.isEmpty {
            inFlightDecodeSubmissions += 1
            let waiter = decodeSubmissionWaiters.removeFirst()
            waiter.resume()
        }
    }
}
