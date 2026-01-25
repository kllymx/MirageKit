//
//  MirageClientService+State.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream state helpers and thread-safe snapshots.
//

import Foundation

@MainActor
extension MirageClientService {
    func setInputBlocked(_ blocked: Bool, for streamID: StreamID) {
        if blocked {
            sendInputReleaseEvents(for: streamID)
        }

        inputBlockedStreamIDsLock.lock()
        if blocked {
            _inputBlockedStreamIDs.insert(streamID)
        } else {
            _inputBlockedStreamIDs.remove(streamID)
        }
        inputBlockedStreamIDsLock.unlock()
    }

    /// Send events to release any potentially held input (mouse buttons, modifiers).
    private func sendInputReleaseEvents(for streamID: StreamID) {
        guard case .connected = connectionState, let connection else { return }

        lastCursorPositionsLock.lock()
        let releaseLocation = _lastCursorPositions[streamID] ?? CGPoint(x: 0.5, y: 0.5)
        lastCursorPositionsLock.unlock()

        do {
            let leftMouseUp = MirageMouseEvent(button: .left, location: releaseLocation, modifiers: [])
            let leftMessage = try ControlMessage(
                type: .inputEvent,
                content: InputEventMessage(streamID: streamID, event: .mouseUp(leftMouseUp))
            )
            connection.send(content: leftMessage.serialize(), completion: .idempotent)

            let rightMouseUp = MirageMouseEvent(button: .right, location: releaseLocation, modifiers: [])
            let rightMessage = try ControlMessage(
                type: .inputEvent,
                content: InputEventMessage(streamID: streamID, event: .rightMouseUp(rightMouseUp))
            )
            connection.send(content: rightMessage.serialize(), completion: .idempotent)

            let middleMouseUp = MirageMouseEvent(button: .middle, location: releaseLocation, modifiers: [])
            let middleMessage = try ControlMessage(
                type: .inputEvent,
                content: InputEventMessage(streamID: streamID, event: .otherMouseUp(middleMouseUp))
            )
            connection.send(content: middleMessage.serialize(), completion: .idempotent)

            let flagsMessage = try ControlMessage(
                type: .inputEvent,
                content: InputEventMessage(streamID: streamID, event: .flagsChanged([]))
            )
            connection.send(content: flagsMessage.serialize(), completion: .idempotent)

            MirageLogger.client("Sent input release events for stream \(streamID) before blocking")
        } catch {
            MirageLogger.error(.client, "Failed to send input release events: \(error)")
        }
    }

    func addActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        _activeStreamIDs.insert(id)
        activeStreamIDsLock.unlock()
    }

    func removeActiveStreamID(_ id: StreamID) {
        activeStreamIDsLock.lock()
        _activeStreamIDs.remove(id)
        activeStreamIDsLock.unlock()

        setInputBlocked(false, for: id)
    }

    func clearAllActiveStreamIDs() {
        activeStreamIDsLock.lock()
        _activeStreamIDs.removeAll()
        activeStreamIDsLock.unlock()

        inputBlockedStreamIDsLock.lock()
        _inputBlockedStreamIDs.removeAll()
        inputBlockedStreamIDsLock.unlock()
    }

    /// Get a snapshot of reassemblers for thread-safe access from UDP callback.
    nonisolated func reassemblerForStream(_ id: StreamID) -> FrameReassembler? {
        reassemblersLock.lock()
        defer { reassemblersLock.unlock() }
        return _reassemblersSnapshot[id]
    }

    func updateReassemblerSnapshot() async {
        var snapshot: [StreamID: FrameReassembler] = [:]
        for (streamID, controller) in controllersByStream {
            snapshot[streamID] = await controller.getReassembler()
        }
        storeReassemblerSnapshot(snapshot)
    }

    private nonisolated func storeReassemblerSnapshot(_ snapshot: [StreamID: FrameReassembler]) {
        reassemblersLock.lock()
        _reassemblersSnapshot = snapshot
        reassemblersLock.unlock()
    }
}
