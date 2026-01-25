//
//  SharedVirtualDisplayManager+ScreenCaptureKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import Foundation
import CoreGraphics

#if os(macOS)
import ScreenCaptureKit

extension SharedVirtualDisplayManager {
    // MARK: - ScreenCaptureKit Integration

    /// Find the SCDisplay corresponding to the shared virtual display
    func findSCDisplay() async throws -> SCDisplayWrapper {
        guard let displayID = sharedDisplay?.displayID else {
            throw SharedDisplayError.noActiveDisplay
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            MirageLogger.error(.host, "SCDisplay not found for displayID \(displayID). Available: \(content.displays.map { $0.displayID })")
            throw SharedDisplayError.scDisplayNotFound(displayID)
        }

        MirageLogger.host("Found SCDisplay \(displayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }

    /// Find the SCDisplay for the main display (used for desktop streaming capture).
    /// When mirroring is active, content renders on the main display even though it shows
    /// the virtual display's content. Capturing the main display ensures SCK sees actual
    /// content changes rather than the mirrored virtual display which may update sporadically.
    func findMainSCDisplay() async throws -> SCDisplayWrapper {
        let mainDisplayID = CGMainDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            MirageLogger.error(.host, "Main SCDisplay not found for displayID \(mainDisplayID). Available: \(content.displays.map { $0.displayID })")
            throw SharedDisplayError.scDisplayNotFound(mainDisplayID)
        }

        MirageLogger.host("Found main SCDisplay \(mainDisplayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }

}
#endif
