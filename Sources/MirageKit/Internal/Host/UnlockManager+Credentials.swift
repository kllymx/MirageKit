#if os(macOS)

//
//  UnlockManager+Credentials.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import Foundation
import AppKit
import CoreGraphics

extension UnlockManager {
    // MARK: - Credential Verification

    /// Verify credentials using macOS Authorization Services
    /// This uses PAM under the hood and is the same mechanism used by the login window
    func verifyCredentialsViaAuthorization(username: String, password: String) -> Bool {
        // Use /usr/bin/dscl to verify password
        // This is more reliable than Authorization APIs for local accounts
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = ["/Local/Default", "-authonly", username, password]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return true
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                MirageLogger.error(.host, "dscl auth failed: \(errorOutput)")
                return false
            }
        } catch {
            MirageLogger.error(.host, "Failed to run dscl: \(error)")
            return false
        }
    }

}

#endif
