//
//  WindowCaptureEngine+Frames.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Frame handling helpers.
//

import Foundation
import CoreMedia
import CoreVideo
import os

#if os(macOS)
import ScreenCaptureKit
import AppKit

extension WindowCaptureEngine {
    func handleFrame(_ frame: CapturedFrame) {
        capturedFrameHandler?(frame)
    }

    func markKeyframeRequested() {
        pendingKeyframeRequest = true
    }

    func consumePendingKeyframeRequest() async -> Bool {
        if pendingKeyframeRequest {
            pendingKeyframeRequest = false
            return true
        }
        return false
    }
}

#endif
