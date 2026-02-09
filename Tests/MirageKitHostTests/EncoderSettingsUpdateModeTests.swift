//
//  EncoderSettingsUpdateModeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/9/26.
//
//  Coverage for bitrate-only encoder setting update classification.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Encoder Settings Update Mode")
struct EncoderSettingsUpdateModeTests {
    @Test("No change keeps no-op update mode")
    func noChangeClassification() {
        let current = makeConfiguration()
        let updated = makeConfiguration()
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: updated) == .noChange)
    }

    @Test("Bitrate-only change uses bitrate-only mode")
    func bitrateOnlyClassification() {
        let current = makeConfiguration()
        let updated = current.withOverrides(bitrate: 250_000_000)
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: updated) == .bitrateOnly)
    }

    @Test("Format or color change uses full reconfiguration")
    func formatOrColorRequiresFullReconfiguration() {
        let current = makeConfiguration()

        let pixelFormatChange = current.withOverrides(pixelFormat: .nv12)
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: pixelFormatChange) == .fullReconfiguration)

        let colorSpaceChange = current.withOverrides(colorSpace: .sRGB)
        #expect(StreamContext.encoderSettingsUpdateMode(current: current, updated: colorSpaceChange) == .fullReconfiguration)
    }

    private func makeConfiguration() -> MirageEncoderConfiguration {
        MirageEncoderConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 1800,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 600_000_000
        )
    }
}
#endif
