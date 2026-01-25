//
//  MirageHostService+InputFast.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Fast input path handling.
//

import Foundation

#if os(macOS)
extension MirageHostService {
    /// Fast input event handler - runs on inputQueue, NOT MainActor.
    func handleInputEventFast(_ message: ControlMessage, from client: MirageConnectedClient) {
        do {
            let inputMessage = try message.decode(InputEventMessage.self)

            if let loginInfo = loginDisplayInputState.getInfo(for: inputMessage.streamID) {
                handleLoginDisplayInputEvent(inputMessage.event, loginInfo: loginInfo)
                return
            }

            guard let cacheEntry = inputStreamCacheActor.get(inputMessage.streamID) else {
                MirageLogger.host("No cached stream for input: \(inputMessage.streamID)")
                return
            }

            if cacheEntry.window.id == 0 {
                let streamID = inputMessage.streamID
                switch inputMessage.event {
                case .relativeResize(let resizeEvent):
                    let newResolution = CGSize(width: resizeEvent.pixelWidth, height: resizeEvent.pixelHeight)
                    Task { @MainActor in
                        await self.handleDisplayResolutionChange(streamID: streamID, newResolution: newResolution)
                    }
                    return
                case .pixelResize(let resizeEvent):
                    let newResolution = CGSize(width: resizeEvent.pixelWidth, height: resizeEvent.pixelHeight)
                    Task { @MainActor in
                        await self.handleDisplayResolutionChange(streamID: streamID, newResolution: newResolution)
                    }
                    return
                default:
                    break
                }
            }

            if let handler = _onInputEvent {
                handler(inputMessage.event, cacheEntry.window, client)
            } else {
                inputController.handleInputEvent(inputMessage.event, window: cacheEntry.window)
            }
        } catch {
            MirageLogger.error(.host, "Failed to decode input event: \(error)")
        }
    }
}
#endif
