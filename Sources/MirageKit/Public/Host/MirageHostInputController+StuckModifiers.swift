//
//  MirageHostInputController+StuckModifiers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Stuck Modifier Detection

    func startModifierResetTimerIfNeeded() {
        guard modifierResetTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: accessibilityQueue)
        timer.schedule(
            deadline: .now() + modifierResetPollIntervalSeconds,
            repeating: modifierResetPollIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            self?.checkForStuckModifiers()
        }
        timer.resume()
        modifierResetTimer = timer
    }

    func stopModifierResetTimer() {
        modifierResetTimer?.cancel()
        modifierResetTimer = nil
    }

    private func checkForStuckModifiers() {
        let now = CACurrentMediaTime()
        let timeSinceLastModifierEvent = now - lastModifierEventTime

        if !lastSentModifiers.isEmpty && timeSinceLastModifierEvent > modifierStuckTimeoutSeconds {
            let roundedDuration = (timeSinceLastModifierEvent * 10).rounded() / 10
            MirageLogger.host("Clearing stuck modifiers after \(roundedDuration)s of inactivity")
            injectFlagsChanged([], app: nil)
        }
    }

    /// Query the actual system modifier state and clear any modifiers that shouldn't be there.
    func clearUnexpectedSystemModifiers() {
        let systemFlags = CGEventSource.flagsState(.hidSystemState)

        var actualModifiers: MirageModifierFlags = []
        for (cgFlag, mirageFlag) in Self.cgFlagToMirageFlag {
            if systemFlags.contains(cgFlag) {
                actualModifiers.insert(mirageFlag)
            }
        }

        if !actualModifiers.isEmpty && lastSentModifiers.isEmpty {
            MirageLogger.host("Clearing unexpected system modifiers: \(actualModifiers)")

            for (flag, keyCode) in Self.modifierKeyCodes where actualModifiers.contains(flag) {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = actualModifiers.cgEventFlags
                    postEvent(keyEvent)
                }
                actualModifiers.remove(flag)
            }

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                postEvent(cgEvent)
            }
        }
    }

    /// Clear all modifier state.
    /// - Note: Call when starting a new stream or reconnecting to avoid stuck modifiers.
    public func clearAllModifiers() {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            guard !self.lastSentModifiers.isEmpty || !self.heldModifierKeyCodes.isEmpty else { return }

            MirageLogger.host("Clearing all modifiers on session change")

            for keyCode in self.heldModifierKeyCodes {
                if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                    keyEvent.flags = []
                    self.postEvent(keyEvent)
                }
            }
            self.heldModifierKeyCodes.removeAll()

            if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                cgEvent.type = .flagsChanged
                cgEvent.flags = []
                self.postEvent(cgEvent)
            }

            self.lastSentModifiers = []
            self.stopModifierResetTimer()
        }
    }

}

#endif
