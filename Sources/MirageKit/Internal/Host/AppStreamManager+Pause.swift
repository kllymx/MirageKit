//
//  AppStreamManager+Pause.swift
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
    // MARK: - Stream Pause/Resume

    /// Pause a stream (client window lost focus)
    public func pauseStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        for (windowID, var info) in sessions[key]?.windowStreams ?? [:] {
            if info.streamID == streamID {
                info.isPaused = true
                sessions[key]?.windowStreams[windowID] = info
                logger.debug("Paused stream \(streamID) for \(bundleIdentifier)")
                break
            }
        }
    }

    /// Resume a stream (client window regained focus)
    public func resumeStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        guard sessions[key] != nil else { return }

        for (windowID, var info) in sessions[key]?.windowStreams ?? [:] {
            if info.streamID == streamID {
                info.isPaused = false
                sessions[key]?.windowStreams[windowID] = info
                logger.debug("Resumed stream \(streamID) for \(bundleIdentifier)")
                break
            }
        }
    }

}

#endif
