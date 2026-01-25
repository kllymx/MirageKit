//
//  SharedVirtualDisplayManager+Cleanup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

#if os(macOS)
import Foundation
import CoreGraphics

extension SharedVirtualDisplayManager {
    // MARK: - Cleanup

    /// Destroy the shared display and clear all consumers
    /// Called during host shutdown
    func destroyAllAndClear() async {
        activeConsumers.removeAll()
        await destroyDisplay()
        MirageLogger.host("Destroyed shared display and cleared all consumers")
    }

    /// Get statistics about the shared display
    func getStatistics() -> (hasDisplay: Bool, consumerCount: Int, resolution: CGSize?) {
        return (
            hasDisplay: sharedDisplay != nil,
            consumerCount: activeConsumers.count,
            resolution: sharedDisplay?.resolution
        )
    }
}
#endif
