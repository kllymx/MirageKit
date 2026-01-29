//
//  MirageCloudKitShareManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/28/26.
//
//  Manages CloudKit sharing for friend access to host.
//

import Foundation
import CloudKit
import Observation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages CloudKit sharing for allowing friends to connect to a host.
///
/// Creates and manages CKShare records that allow other iCloud users
/// to connect without manual approval.
///
/// ## Usage
///
/// ```swift
/// let shareManager = MirageCloudKitShareManager(cloudKitManager: cloudKitManager)
/// await shareManager.setup()
///
/// // Present sharing UI (macOS)
/// try await shareManager.presentSharingUI(from: window)
///
/// // Or create sharing controller (iOS/visionOS)
/// let controller = try await shareManager.createSharingController()
/// ```
@Observable
@MainActor
public final class MirageCloudKitShareManager: Sendable {
    // MARK: - Properties

    /// CloudKit manager for container access.
    private let cloudKitManager: MirageCloudKitManager

    /// Current active share for this host, if any.
    public private(set) var activeShare: CKShare?

    /// Host record used as the root for sharing.
    public private(set) var hostRecord: CKRecord?

    /// Whether share operations are in progress.
    public private(set) var isLoading: Bool = false

    /// Last error from share operations.
    public private(set) var lastError: Error?

    /// Custom zone for host records.
    private let hostZoneID: CKRecordZone.ID

    // MARK: - Initialization

    /// Creates a share manager with the specified CloudKit manager.
    ///
    /// - Parameter cloudKitManager: The CloudKit manager providing container access.
    public init(cloudKitManager: MirageCloudKitManager) {
        self.cloudKitManager = cloudKitManager
        self.hostZoneID = CKRecordZone.ID(
            zoneName: cloudKitManager.configuration.hostZoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    // MARK: - Setup

    /// Ensures the host zone exists and fetches any existing host record and share.
    ///
    /// Call this after the CloudKit manager is initialized to set up sharing.
    public func setup() async {
        guard cloudKitManager.isAvailable else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            // Create zone if needed
            let zone = CKRecordZone(zoneID: hostZoneID)
            _ = try await cloudKitManager.container.privateCloudDatabase.modifyRecordZones(
                saving: [zone],
                deleting: []
            )

            // Fetch existing host record
            await fetchHostRecord()

            // Fetch existing share if host record exists
            if let hostRecord {
                await fetchShare(for: hostRecord)
            }

        } catch {
            lastError = error
            MirageLogger.error(.appState, "Failed to setup share manager: \(error)")
        }
    }

    // MARK: - Host Record Management

    /// Fetches or creates the host record.
    private func fetchHostRecord() async {
        let database = cloudKitManager.container.privateCloudDatabase

        // Query for existing host record
        let query = CKQuery(
            recordType: cloudKitManager.configuration.hostRecordType,
            predicate: NSPredicate(value: true)
        )

        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: hostZoneID)

            for (_, result) in results {
                if case .success(let record) = result {
                    hostRecord = record
                    MirageLogger.appState("Found existing host record")
                    return
                }
            }

            // No existing record - will create when sharing
            MirageLogger.appState("No existing host record found")

        } catch {
            MirageLogger.error(.appState, "Failed to fetch host record: \(error)")
        }
    }

    /// Creates a new host record for sharing.
    private func createHostRecord() async throws -> CKRecord {
        let database = cloudKitManager.container.privateCloudDatabase

        #if os(macOS)
        let hostName = Host.current().localizedName ?? "Mac"
        #else
        let hostName = "My Mac"
        #endif

        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: hostZoneID)
        let record = CKRecord(recordType: cloudKitManager.configuration.hostRecordType, recordID: recordID)
        record["name"] = hostName
        record["createdAt"] = Date()

        let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [])

        guard let savedRecord = try saveResults[recordID]?.get() else {
            throw MirageCloudKitError.recordNotSaved
        }

        hostRecord = savedRecord
        MirageLogger.appState("Created new host record: \(hostName)")
        return savedRecord
    }

    // MARK: - Share Management

    /// Fetches the share for a host record.
    private func fetchShare(for record: CKRecord) async {
        guard let shareReference = record.share else {
            MirageLogger.appState("Host record has no share")
            return
        }

        do {
            let database = cloudKitManager.container.privateCloudDatabase
            let share = try await database.record(for: shareReference.recordID) as? CKShare
            activeShare = share
            MirageLogger.appState("Found existing share with \(share?.participants.count ?? 0) participants")
        } catch {
            MirageLogger.error(.appState, "Failed to fetch share: \(error)")
        }
    }

    /// Creates a new share for the host.
    ///
    /// - Returns: The created share, ready for presenting sharing UI.
    public func createShare() async throws -> CKShare {
        isLoading = true
        defer { isLoading = false }

        // Get or create host record
        let record: CKRecord
        if let existing = hostRecord {
            record = existing
        } else {
            record = try await createHostRecord()
        }

        // Create share
        let share = CKShare(rootRecord: record)
        share[CKShare.SystemFieldKey.title] = cloudKitManager.configuration.shareTitle
        share.publicPermission = .none  // Participants only

        // Save both record and share
        let database = cloudKitManager.container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [record, share], deleting: [])

        activeShare = share
        MirageLogger.appState("Created new share for host")
        return share
    }

    /// Revokes an existing share.
    ///
    /// This removes access for all participants.
    public func revokeShare() async throws {
        guard let share = activeShare else { return }

        isLoading = true
        defer { isLoading = false }

        let database = cloudKitManager.container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [], deleting: [share.recordID])

        activeShare = nil
        MirageLogger.appState("Revoked host share")
    }

    /// Removes a specific participant from the share.
    ///
    /// - Parameter participant: The participant to remove.
    public func removeParticipant(_ participant: CKShare.Participant) async throws {
        guard let share = activeShare else { return }

        share.removeParticipant(participant)

        let database = cloudKitManager.container.privateCloudDatabase
        _ = try await database.modifyRecords(saving: [share], deleting: [])

        MirageLogger.appState("Removed participant from share")

        // Refresh the CloudKit manager's cache
        cloudKitManager.clearShareParticipantCache()
    }

    // MARK: - Share UI Presentation

    #if os(macOS)
    /// Presents the sharing UI on macOS.
    ///
    /// - Parameter window: The window to present from.
    public func presentSharingUI(from window: NSWindow) async throws {
        let share: CKShare
        if let existing = activeShare {
            share = existing
        } else {
            share = try await createShare()
        }

        guard hostRecord != nil else {
            throw MirageCloudKitError.noHostRecord
        }

        let sharingService = NSSharingService(named: .cloudSharing)
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: cloudKitManager.container)

        // Present the sharing service picker
        if let sharingService {
            sharingService.perform(withItems: [itemProvider])
        }
    }
    #endif

    #if os(iOS) || os(visionOS)
    /// Creates a UICloudSharingController for presenting sharing UI on iOS/visionOS.
    ///
    /// - Returns: A configured sharing controller ready for presentation.
    public func createSharingController() async throws -> UICloudSharingController {
        let share: CKShare
        if let existing = activeShare {
            share = existing
        } else {
            share = try await createShare()
        }

        guard hostRecord != nil else {
            throw MirageCloudKitError.noHostRecord
        }

        let controller = UICloudSharingController(share: share, container: cloudKitManager.container)
        controller.availablePermissions = [.allowReadWrite]

        return controller
    }
    #endif

    // MARK: - Share Acceptance

    /// Handles acceptance of a share from another user.
    ///
    /// Call this from your app's share acceptance handler (e.g., `userDidAcceptCloudKitShare`).
    ///
    /// - Parameter metadata: The share metadata from the URL.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        try await cloudKitManager.container.accept(metadata)
        MirageLogger.appState("Accepted share from \(metadata.ownerIdentity.nameComponents?.formatted() ?? "unknown")")

        // Refresh participant cache
        cloudKitManager.clearShareParticipantCache()
    }
}

// MARK: - Errors

/// Errors specific to CloudKit sharing operations.
public enum MirageCloudKitError: LocalizedError, Sendable {
    /// Failed to save record to CloudKit.
    case recordNotSaved

    /// No host record available for sharing.
    case noHostRecord

    /// Share not found.
    case shareNotFound

    public var errorDescription: String? {
        switch self {
        case .recordNotSaved:
            return "Failed to save record to CloudKit"
        case .noHostRecord:
            return "No host record available for sharing"
        case .shareNotFound:
            return "Share not found"
        }
    }
}
