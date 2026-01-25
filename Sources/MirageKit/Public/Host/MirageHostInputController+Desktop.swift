//
//  MirageHostInputController+Desktop.swift
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
    // MARK: - Desktop Input Handling

    /// Handle input events for desktop streaming.
    /// - Parameters:
    ///   - event: The input event received from the client.
    ///   - bounds: Bounds of the virtual display or mirrored desktop.
    public func handleDesktopInputEvent(_ event: MirageInputEvent, bounds: CGRect) {
        accessibilityQueue.async { [weak self] in
            guard let self else { return }

            switch event {
            case .mouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.leftMouseDown, e, at: point)
            case .mouseUp(let e):
                self.flushPointerLerp()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.leftMouseUp, e, at: point)
            case .rightMouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.rightMouseDown, e, at: point)
            case .rightMouseUp(let e):
                self.flushPointerLerp()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.rightMouseUp, e, at: point)
            case .otherMouseDown(let e):
                self.flushPointerLerp()
                self.clearUnexpectedSystemModifiers()
                let point = self.screenPoint(e.location, in: bounds)
                CGWarpMouseCursorPosition(point)
                self.injectDesktopMouseEvent(.otherMouseDown, e, at: point)
            case .otherMouseUp(let e):
                self.flushPointerLerp()
                let point = self.screenPoint(e.location, in: bounds)
                self.injectDesktopMouseEvent(.otherMouseUp, e, at: point)

            case .mouseMoved(let e):
                self.queuePointerLerp(.mouseMoved, e, bounds, windowID: 0, app: nil, isDesktop: true)
            case .mouseDragged(let e):
                self.queuePointerLerp(.leftMouseDragged, e, bounds, windowID: 0, app: nil, isDesktop: true)
            case .rightMouseDragged(let e):
                self.queuePointerLerp(.rightMouseDragged, e, bounds, windowID: 0, app: nil, isDesktop: true)
            case .otherMouseDragged(let e):
                self.queuePointerLerp(.otherMouseDragged, e, bounds, windowID: 0, app: nil, isDesktop: true)

            case .scrollWheel(let e):
                self.injectDesktopScrollEvent(e, bounds: bounds)

            case .keyDown(let e):
                self.flushPointerLerp()
                self.injectKeyEvent(isKeyDown: true, e, app: nil)
            case .keyUp(let e):
                self.flushPointerLerp()
                self.injectKeyEvent(isKeyDown: false, e, app: nil)
            case .flagsChanged(let modifiers):
                self.injectFlagsChanged(modifiers, app: nil)

            case .magnify(let e):
                self.handleMagnifyGesture(e, windowFrame: bounds)

            case .rotate(let e):
                self.handleRotateGesture(e, windowFrame: bounds)

            case .windowResize, .relativeResize, .pixelResize:
                break

            case .windowFocus:
                break
            }
        }
    }

    /// Convert normalized coordinates (0-1) to screen coordinates using display bounds.
    func screenPoint(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.origin.x + normalized.x * bounds.width,
            y: bounds.origin.y + normalized.y * bounds.height
        )
    }

    /// Inject mouse event at a specific screen point (for desktop streaming).
    func injectDesktopMouseEvent(_ type: CGEventType, _ event: MirageMouseEvent, at point: CGPoint) {
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: event.button.cgMouseButton
        ) else { return }

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount))
        default:
            break
        }

        postEvent(cgEvent)
    }

    /// Inject scroll event for desktop streaming.
    private func injectDesktopScrollEvent(_ event: MirageScrollEvent, bounds: CGRect) {
        let scrollPoint: CGPoint
        if let normalizedLocation = event.location {
            scrollPoint = screenPoint(normalizedLocation, in: bounds)
        } else {
            scrollPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        postEvent(cgEvent)
    }

}

#endif
