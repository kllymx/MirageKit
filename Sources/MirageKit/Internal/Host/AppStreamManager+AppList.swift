//
//  AppStreamManager+AppList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  App stream manager extensions.
//

#if os(macOS)
import Foundation
import AppKit

extension AppStreamManager {
    // MARK: - App List

    /// Get list of installed apps with streaming status
    public func getInstalledApps(includeIcons: Bool = true) async -> [MirageInstalledApp] {
        let runningApps = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier?.lowercased() }
        )

        let streamingApps = Set(sessions.keys.map { $0.lowercased() })

        return await applicationScanner.scanInstalledApps(
            includeIcons: includeIcons,
            runningApps: runningApps,
            streamingApps: streamingApps
        )
    }

    /// Check if an app is available for streaming (not already being streamed)
    public func isAppAvailableForStreaming(_ bundleIdentifier: String) -> Bool {
        let key = bundleIdentifier.lowercased()

        guard let session = sessions[key] else {
            return true // Not being streamed
        }

        // Check if reservation has expired
        if session.reservationExpired {
            return true
        }

        return false
    }

    /// Get the client ID that has exclusive access to an app (if any)
    public func clientStreamingApp(_ bundleIdentifier: String) -> UUID? {
        let key = bundleIdentifier.lowercased()
        guard let session = sessions[key], !session.reservationExpired else {
            return nil
        }
        return session.clientID
    }

}

#endif
