//
//  MirageHostInputController+Keys.swift
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
    // MARK: - Key Event Injection (runs on accessibilityQueue)

    func injectKeyEvent(isKeyDown: Bool, _ event: MirageKeyEvent, app: MirageApplication?) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: isKeyDown
        ) else { return }

        cgEvent.flags = event.modifiers.cgEventFlags

        if event.isRepeat {
            cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }

        postEvent(cgEvent)

        if !event.modifiers.isEmpty {
            lastModifierEventTime = CACurrentMediaTime()
        }
    }

    func injectFlagsChanged(_ modifiers: MirageModifierFlags, app: MirageApplication?) {
        var newlyPressed: [CGKeyCode] = []
        var newlyReleased: [CGKeyCode] = []

        for (flag, keyCode) in Self.modifierKeyCodes {
            let wasHeld = lastSentModifiers.contains(flag)
            let isHeld = modifiers.contains(flag)

            if isHeld && !wasHeld {
                newlyPressed.append(keyCode)
            } else if !isHeld && wasHeld {
                newlyReleased.append(keyCode)
            }
        }

        var cumulativeFlags = lastSentModifiers
        for (flag, keyCode) in Self.modifierKeyCodes where newlyPressed.contains(keyCode) {
            cumulativeFlags.insert(flag)
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                keyEvent.flags = cumulativeFlags.cgEventFlags
                postEvent(keyEvent)
                heldModifierKeyCodes.insert(keyCode)
            }
        }

        var releaseFlags = cumulativeFlags
        for (flag, keyCode) in Self.modifierKeyCodes where newlyReleased.contains(keyCode) {
            if let keyEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                keyEvent.flags = releaseFlags.cgEventFlags
                postEvent(keyEvent)
                heldModifierKeyCodes.remove(keyCode)
            }
            releaseFlags.remove(flag)
        }

        if let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
            cgEvent.type = .flagsChanged
            cgEvent.flags = modifiers.cgEventFlags
            postEvent(cgEvent)
        }

        lastSentModifiers = modifiers
        lastModifierEventTime = CACurrentMediaTime()

        if !modifiers.isEmpty {
            startModifierResetTimerIfNeeded()
        } else {
            stopModifierResetTimer()
        }
    }

}

#endif
