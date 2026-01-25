//
//  MirageHostInputController+Gestures.swift
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
    // MARK: - Gesture Translation (runs on accessibilityQueue)

    func handleMagnifyGesture(_ event: MirageMagnifyEvent, windowFrame: CGRect) {
        switch event.phase {
        case .began:
            magnifyAccumulator = 0
        case .changed:
            magnifyAccumulator += event.magnification

            if abs(magnifyAccumulator) >= magnifyScrollThreshold {
                let scrollDelta = Int32(-magnifyAccumulator * 50)
                injectScrollWithModifier(
                    deltaY: scrollDelta,
                    modifier: .maskCommand,
                    windowFrame: windowFrame
                )
                magnifyAccumulator = 0
            }
        case .ended, .cancelled:
            if abs(magnifyAccumulator) > 0.005 {
                let scrollDelta = Int32(-magnifyAccumulator * 50)
                injectScrollWithModifier(
                    deltaY: scrollDelta,
                    modifier: .maskCommand,
                    windowFrame: windowFrame
                )
            }
            magnifyAccumulator = 0
        default:
            break
        }
    }

    func handleRotateGesture(_ event: MirageRotateEvent, windowFrame: CGRect) {
        switch event.phase {
        case .began:
            rotationAccumulator = 0
        case .changed:
            rotationAccumulator += event.rotation

            if abs(rotationAccumulator) >= rotationScrollThreshold {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
                rotationAccumulator = 0
            }
        case .ended, .cancelled:
            if abs(rotationAccumulator) > 0.5 {
                let scrollDelta = Int32(rotationAccumulator * 2)
                injectScrollWithModifier(
                    deltaX: scrollDelta,
                    modifier: .maskAlternate,
                    windowFrame: windowFrame
                )
            }
            rotationAccumulator = 0
        default:
            break
        }
    }

    private func injectScrollWithModifier(
        deltaX: Int32 = 0,
        deltaY: Int32 = 0,
        modifier: CGEventFlags,
        windowFrame: CGRect
    ) {
        let scrollPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        cgEvent.flags = modifier
        postEvent(cgEvent)
    }

}

#endif
