//
//  MirageHostService+SessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Session state updates and window list delivery.
//

import Foundation

#if os(macOS)
@MainActor
extension MirageHostService {
    func startSessionStateMonitoring() async {
        if sessionStateMonitor == nil {
            sessionStateMonitor = SessionStateMonitor()
        }

        if unlockManager == nil, let sessionStateMonitor {
            unlockManager = UnlockManager(sessionMonitor: sessionStateMonitor)
        }

        guard let sessionStateMonitor else { return }

        await sessionStateMonitor.start { [weak self] newState in
            Task { @MainActor [weak self] in
                await self?.handleSessionStateChange(newState)
            }
        }

        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState {
            await handleSessionStateChange(refreshed)
        }
    }

    func refreshSessionStateIfNeeded() async {
        guard let sessionStateMonitor else { return }
        let refreshed = await sessionStateMonitor.refreshState(notify: false)
        if refreshed != sessionState {
            await handleSessionStateChange(refreshed)
        }
    }

    func handleSessionStateChange(_ newState: HostSessionState) async {
        sessionState = newState
        currentSessionToken = UUID().uuidString

        delegate?.hostService(self, sessionStateChanged: newState)

        for clientContext in clientsByConnection.values {
            await sendSessionState(to: clientContext)
        }

        if newState == .active {
            await stopLoginDisplayStream(newState: newState)
            await unlockManager?.releaseDisplayAssertion()
            for clientContext in clientsByConnection.values {
                await sendWindowList(to: clientContext)
            }
        } else if !clientsByConnection.isEmpty {
            await startLoginDisplayStreamIfNeeded()
        }
    }

    func sendSessionState(to clientContext: ClientContext) async {
        let message = SessionStateUpdateMessage(
            state: sessionState,
            sessionToken: currentSessionToken,
            requiresUsername: sessionState.requiresUsername,
            timestamp: Date()
        )

        do {
            try await clientContext.send(.sessionStateUpdate, content: message)
        } catch {
            MirageLogger.error(.host, "Failed to send session state: \(error)")
        }
    }

    func sendWindowList(to clientContext: ClientContext) async {
        do {
            let windowList = WindowListMessage(windows: availableWindows)
            try await clientContext.send(.windowList, content: windowList)
            MirageLogger.host("Sent window list with \(availableWindows.count) windows")
        } catch {
            MirageLogger.error(.host, "Failed to send window list: \(error)")
        }
    }
}
#endif
