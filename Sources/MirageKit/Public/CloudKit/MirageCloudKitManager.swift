//
//  MirageCloudKitManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages CloudKit operations for device registration and user identity.
//

import Foundation
import CloudKit
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Manages CloudKit operations for iCloud-based trust.
///
/// Handles device registration, user identity fetching, and share participant caching.
/// Initialize with a ``MirageCloudKitConfiguration`` to customize behavior.
///
/// ## Usage
///
/// ```swift
/// let config = MirageCloudKitConfiguration(
///     containerIdentifier: "iCloud.com.yourcompany.YourApp"
/// )
/// let manager = MirageCloudKitManager(configuration: config)
/// await manager.initialize()
/// ```
@Observable
@MainActor
public final class MirageCloudKitManager: Sendable {
    // MARK: - Properties

    /// Configuration for CloudKit operations.
    public let configuration: MirageCloudKitConfiguration

    /// CloudKit container.
    public let container: CKContainer

    /// Current user's CloudKit record ID (recordName portion).
    public private(set) var currentUserRecordID: String?

    /// Whether CloudKit is available and the user is signed in.
    public private(set) var isAvailable: Bool = false

    /// Last error encountered during CloudKit operations.
    public private(set) var lastError: Error?

    /// Whether initial setup has completed.
    public private(set) var isInitialized: Bool = false

    /// Cache of share participant user IDs with expiration.
    private var shareParticipantCache: [String: Date] = [:]

    // MARK: - Initialization

    /// Creates a CloudKit manager with the specified configuration.
    ///
    /// - Parameter configuration: CloudKit configuration including container ID and record types.
    public init(configuration: MirageCloudKitConfiguration) {
        self.configuration = configuration
        self.container = CKContainer(identifier: configuration.containerIdentifier)
    }

    /// Creates a CloudKit manager with just a container identifier, using default settings.
    ///
    /// - Parameter containerIdentifier: CloudKit container identifier.
    public convenience init(containerIdentifier: String) {
        self.init(configuration: MirageCloudKitConfiguration(containerIdentifier: containerIdentifier))
    }

    // MARK: - Setup

    /// Initializes CloudKit and fetches the current user's record ID.
    ///
    /// Call this early in your app's lifecycle to set up CloudKit.
    /// This method registers the current device and caches the user's identity.
    public func initialize() async {
        guard !isInitialized else { return }

        do {
            // Check account status
            let status = try await container.accountStatus()

            switch status {
            case .available:
                isAvailable = true
                MirageLogger.appState("CloudKit available")

            case .noAccount:
                isAvailable = false
                MirageLogger.appState("CloudKit: No iCloud account signed in")
                return

            case .restricted, .couldNotDetermine, .temporarilyUnavailable:
                isAvailable = false
                MirageLogger.appState("CloudKit: Account status \(status)")
                return

            @unknown default:
                isAvailable = false
                return
            }

            // Fetch current user's record ID
            let userRecordID = try await container.userRecordID()
            currentUserRecordID = userRecordID.recordName
            MirageLogger.appState("CloudKit user ID: \(userRecordID.recordName)")

            // Register this device
            await registerCurrentDevice()

            isInitialized = true

        } catch {
            lastError = error
            isAvailable = false
            MirageLogger.error(.appState, "CloudKit initialization failed: \(error)")
        }
    }

    /// Reinitializes CloudKit after an account change.
    ///
    /// Call this when you detect an iCloud account change to refresh
    /// the user identity and device registration.
    public func reinitialize() async {
        isInitialized = false
        currentUserRecordID = nil
        isAvailable = false
        shareParticipantCache.removeAll()
        await initialize()
    }

    // MARK: - Device Registration

    /// Registers the current device in the user's private CloudKit database.
    private func registerCurrentDevice() async {
        guard isAvailable else { return }

        #if os(macOS)
        let deviceName = Host.current().localizedName ?? "Mac"
        let deviceType = "mac"
        #elseif os(iOS)
        let deviceName = UIDevice.current.name
        let deviceType = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(visionOS)
        let deviceName = "Apple Vision Pro"
        let deviceType = "vision"
        #else
        let deviceName = "Unknown Device"
        let deviceType = "unknown"
        #endif

        // Use a stable device identifier
        let deviceID = getOrCreateDeviceID()

        let recordID = CKRecord.ID(recordName: deviceID.uuidString)
        let record = CKRecord(recordType: configuration.deviceRecordType, recordID: recordID)
        record["name"] = deviceName
        record["deviceType"] = deviceType
        record["lastSeen"] = Date()

        do {
            let database = container.privateCloudDatabase
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            MirageLogger.appState("Registered device in CloudKit: \(deviceName)")
        } catch {
            // Don't treat registration failures as critical
            MirageLogger.error(.appState, "Failed to register device in CloudKit: \(error)")
        }
    }

    /// Returns a stable device identifier, creating one if needed.
    private func getOrCreateDeviceID() -> UUID {
        let key = configuration.deviceIDKey
        if let storedID = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: storedID) {
            return uuid
        }

        let newID = UUID()
        UserDefaults.standard.set(newID.uuidString, forKey: key)
        return newID
    }

    // MARK: - Share Participant Checking

    /// Checks if a user ID is a participant in any accepted shares.
    ///
    /// - Parameter userID: The CloudKit user record ID to check.
    /// - Returns: Whether the user is a share participant.
    public func isShareParticipant(userID: String) async -> Bool {
        // Check cache first
        if let expiration = shareParticipantCache[userID], expiration > Date() {
            return true
        }

        guard isAvailable else { return false }

        do {
            // Fetch all accepted shares in the shared database
            let sharedDatabase = container.sharedCloudDatabase
            let zones = try await sharedDatabase.allRecordZones()

            for zone in zones {
                // Get the share for this zone
                if let share = try await fetchShareForZone(zone, in: sharedDatabase) {
                    // Check if the user is a participant
                    for participant in share.participants {
                        if let participantUserID = participant.userIdentity.userRecordID?.recordName,
                           participantUserID == userID {
                            // Cache the result
                            shareParticipantCache[userID] = Date().addingTimeInterval(configuration.shareParticipantCacheTTL)
                            return true
                        }
                    }
                }
            }

            return false

        } catch {
            MirageLogger.error(.appState, "Failed to check share participants: \(error)")
            return false
        }
    }

    /// Fetches the CKShare for a record zone if one exists.
    private func fetchShareForZone(_ zone: CKRecordZone, in database: CKDatabase) async throws -> CKShare? {
        let query = CKQuery(recordType: "cloudkit.share", predicate: NSPredicate(value: true))
        let (results, _) = try await database.records(matching: query, inZoneWith: zone.zoneID)

        for (_, result) in results {
            if case .success(let record) = result, let share = record as? CKShare {
                return share
            }
        }

        return nil
    }

    /// Clears the share participant cache.
    ///
    /// Call this after share membership changes to ensure fresh data.
    public func clearShareParticipantCache() {
        shareParticipantCache.removeAll()
    }

    /// Refreshes share participant data from CloudKit.
    ///
    /// Clears the cache so the next ``isShareParticipant(userID:)`` call fetches fresh data.
    public func refreshShareParticipants() async {
        shareParticipantCache.removeAll()
    }

    // MARK: - Account Change Handling

    /// Handles iCloud account changes by reinitializing.
    ///
    /// Call this from your app's account change notification handler.
    public func handleAccountChange() async {
        MirageLogger.appState("iCloud account changed, reinitializing CloudKit")
        await reinitialize()
    }
}
