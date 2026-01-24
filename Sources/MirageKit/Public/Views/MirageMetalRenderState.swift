//
//  MirageMetalRenderState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import CoreVideo
import Metal

final class MirageMetalRenderState {
    private weak var lastPixelBuffer: CVPixelBuffer?
    private var lastRenderedSequence: UInt64 = 0
    private var needsRedraw = true

    private(set) var currentTexture: MTLTexture?
    private(set) var currentContentRect: CGRect = .zero

    func reset() {
        lastRenderedSequence = 0
        needsRedraw = true
        lastPixelBuffer = nil
        currentTexture = nil
        currentContentRect = .zero
    }

    func markNeedsRedraw() {
        needsRedraw = true
    }

    @discardableResult
    func updateFrameIfNeeded(streamID: StreamID?, renderer: MetalRenderer?) -> Bool {
        guard let id = streamID, let entry = MirageFrameCache.shared.getEntry(for: id) else { return false }
        let hasNewFrame = entry.sequence != lastRenderedSequence
        guard hasNewFrame || needsRedraw else { return false }

        if let texture = entry.texture {
            currentTexture = texture
            lastPixelBuffer = entry.pixelBuffer
        } else if hasNewFrame || currentTexture == nil || entry.pixelBuffer !== lastPixelBuffer {
            currentTexture = renderer?.createTexture(from: entry.pixelBuffer)
            lastPixelBuffer = entry.pixelBuffer
        }

        guard currentTexture != nil else { return false }

        currentContentRect = entry.contentRect
        lastRenderedSequence = entry.sequence
        needsRedraw = false
        return true
    }
}
