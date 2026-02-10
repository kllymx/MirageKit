//
//  StreamScaleQuantizationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Stream scale quantization coverage.
//

@testable import MirageKitHost
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Stream Scale Quantization")
struct StreamScaleQuantizationTests {
    @Test("6K base caps to 5K even")
    func sixKBaseCapsToFiveKEven() {
        let baseSize = CGSize(width: 6016, height: 3384)
        let resolvedScale = resolvedStreamScale(
            baseSize: baseSize,
            requestedScale: 1.0
        )

        #expect(abs(resolvedScale - (5120.0 / 6016.0)) < 0.0001)

        let width = StreamContext.alignedEvenPixel(baseSize.width * resolvedScale)
        let height = StreamContext.alignedEvenPixel(baseSize.height * resolvedScale)
        #expect(width == 5120)
        #expect(height == 2880)
    }

    @Test("16:10 base caps by height")
    func sixteenByTenCapsByHeight() {
        let baseSize = CGSize(width: 6400, height: 4000)
        let resolvedScale = resolvedStreamScale(
            baseSize: baseSize,
            requestedScale: 1.0
        )

        #expect(abs(resolvedScale - 0.72) < 0.0001)

        let width = StreamContext.alignedEvenPixel(baseSize.width * resolvedScale)
        let height = StreamContext.alignedEvenPixel(baseSize.height * resolvedScale)
        #expect(width == 4608)
        #expect(height == 2880)
    }

    @Test("4:3 base caps by height")
    func fourByThreeCapsByHeight() {
        let baseSize = CGSize(width: 4096, height: 3072)
        let resolvedScale = resolvedStreamScale(
            baseSize: baseSize,
            requestedScale: 1.0
        )

        #expect(abs(resolvedScale - 0.9375) < 0.0001)

        let width = StreamContext.alignedEvenPixel(baseSize.width * resolvedScale)
        let height = StreamContext.alignedEvenPixel(baseSize.height * resolvedScale)
        #expect(width == 3840)
        #expect(height == 2880)
    }

    @Test("Uncapped mode preserves requested scale")
    func uncappedModePreservesScale() {
        let baseSize = CGSize(width: 6016, height: 3384)
        let resolvedScale = resolvedStreamScale(
            baseSize: baseSize,
            requestedScale: 1.0,
            disableResolutionCap: true
        )

        #expect(abs(resolvedScale - 1.0) < 0.0001)
    }
}

private func resolvedStreamScale(
    baseSize: CGSize,
    requestedScale: CGFloat,
    disableResolutionCap: Bool = false
) -> CGFloat {
    let clamped = StreamContext.clampStreamScale(requestedScale)
    if disableResolutionCap { return clamped }
    let maxScale = min(
        1.0,
        StreamContext.maxEncodedWidth / baseSize.width,
        StreamContext.maxEncodedHeight / baseSize.height
    )
    return min(clamped, maxScale)
}
#endif
