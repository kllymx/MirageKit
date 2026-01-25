//
//  MirageHostInputController+Input.swift
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
    // MARK: - Input Handling

    func handleInput(_ event: MirageInputEvent, window: MirageWindow) {
        let windowFrame = window.frame

        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case .mouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.leftMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .mouseUp(let e):
                self.flushPointerLerp()
                self.injectMouseEvent(.leftMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case .rightMouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.rightMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .rightMouseUp(let e):
                self.flushPointerLerp()
                self.injectMouseEvent(.rightMouseUp, e, windowFrame, windowID: window.id, app: window.application)
            case .otherMouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectMouseEvent(.otherMouseDown, e, windowFrame, windowID: window.id, app: window.application)
            case .otherMouseUp(let e):
                self.flushPointerLerp()
                self.injectMouseEvent(.otherMouseUp, e, windowFrame, windowID: window.id, app: window.application)

            case .mouseMoved(let e):
                self.queuePointerLerp(.mouseMoved, e, windowFrame, windowID: window.id, app: window.application, isDesktop: false)
            case .mouseDragged(let e):
                self.queuePointerLerp(.leftMouseDragged, e, windowFrame, windowID: window.id, app: window.application, isDesktop: false)
            case .rightMouseDragged(let e):
                self.queuePointerLerp(.rightMouseDragged, e, windowFrame, windowID: window.id, app: window.application, isDesktop: false)
            case .otherMouseDragged(let e):
                self.queuePointerLerp(.otherMouseDragged, e, windowFrame, windowID: window.id, app: window.application, isDesktop: false)

            case .scrollWheel(let e):
                self.batchScroll(e, windowFrame, app: window.application)

            case .keyDown(let e):
                self.flushPointerLerp()
                self.activateWindow(windowID: window.id, app: window.application)
                self.injectKeyEvent(isKeyDown: true, e, app: window.application)
            case .keyUp(let e):
                self.flushPointerLerp()
                self.injectKeyEvent(isKeyDown: false, e, app: window.application)
            case .flagsChanged(let modifiers):
                self.injectFlagsChanged(modifiers, app: window.application)

            case .magnify(let e):
                self.handleMagnifyGesture(e, windowFrame: windowFrame)

            case .rotate(let e):
                self.handleRotateGesture(e, windowFrame: windowFrame)

            case .windowResize, .relativeResize, .pixelResize:
                break

            case .windowFocus:
                self.activateWindow(windowID: window.id, app: window.application)
            }
        }
    }

}

#endif
