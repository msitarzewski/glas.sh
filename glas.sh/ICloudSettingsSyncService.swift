import Foundation

enum ICloudSettingsSyncStatus: String, Equatable, Sendable {
    case disabled
    case syncing
    case synced
    case unavailable
    case quota
    case account
    case error
}

enum ICloudSettingsStoreChangeReason: Equatable, Sendable {
    case server
    case initialSync
    case quota
    case account
    case unknown(Int)
}

struct ICloudSettingsStoreChange: Equatable, Sendable {
    let reason: ICloudSettingsStoreChangeReason
    let changedKeys: Set<String>
}

@MainActor
protocol ICloudSettingsKeyValueStore: AnyObject {
    var isAvailable: Bool { get }
    var isAccountAvailable: Bool { get }

    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
    func observeExternalChanges(
        _ handler: @escaping @MainActor @Sendable (ICloudSettingsStoreChange) -> Void
    ) -> NSObjectProtocol
    func removeExternalChangeObserver(_ observer: NSObjectProtocol)
}

/// Live adapter for Apple's iCloud key-value store. The protocol boundary keeps
/// synchronization tests independent of the signed-in Apple account and app
/// entitlements on the machine running them.
@MainActor
final class NSUbiquitousSettingsKeyValueStore: ICloudSettingsKeyValueStore {
    private let store: NSUbiquitousKeyValueStore
    private let notificationCenter: NotificationCenter
    private let fileManager: FileManager

    init(
        store: NSUbiquitousKeyValueStore = .default,
        notificationCenter: NotificationCenter = .default,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.notificationCenter = notificationCenter
        self.fileManager = fileManager
    }

    var isAvailable: Bool { true }
    var isAccountAvailable: Bool { fileManager.ubiquityIdentityToken != nil }

    func data(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        store.set(data, forKey: key)
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    func observeExternalChanges(
        _ handler: @escaping @MainActor @Sendable (ICloudSettingsStoreChange) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { notification in
            let rawReason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey]
                as? Int ?? -1
            let reason: ICloudSettingsStoreChangeReason
            switch rawReason {
            case NSUbiquitousKeyValueStoreServerChange:
                reason = .server
            case NSUbiquitousKeyValueStoreInitialSyncChange:
                reason = .initialSync
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                reason = .quota
            case NSUbiquitousKeyValueStoreAccountChange:
                reason = .account
            default:
                reason = .unknown(rawReason)
            }

            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey]
                as? [String] ?? []
            let change = ICloudSettingsStoreChange(
                reason: reason,
                changedKeys: Set(changedKeys)
            )
            Task { @MainActor in
                handler(change)
            }
        }
    }

    func removeExternalChangeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}

/// A platform-neutral color representation used only by the sync payload.
/// Keeping this independent from SwiftUI lets the transport remain
/// Foundation-only and makes validation deterministic in unit tests.
struct ICloudTerminalColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    func validate() throws {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ICloudSettingsSyncError.invalidPayload("Theme colors must use finite 0...1 components.")
        }
    }
}

/// Portable terminal appearance. ANSI colors are stored in terminal index
/// order: normal 0...7 followed by bright 8...15.
struct ICloudTerminalTheme: Codable, Equatable, Identifiable, Sendable {
    static let maximumNameLength = TerminalTheme.maximumNameLength
    static let maximumFontNameLength = TerminalTheme.maximumFontNameLength

    let id: UUID
    var name: String
    var background: ICloudTerminalColor
    var foreground: ICloudTerminalColor
    var cursor: ICloudTerminalColor
    var selection: ICloudTerminalColor
    var ansiColors: [ICloudTerminalColor]
    var fontName: String
    var fontSize: Double
    var preferredAppearance: TerminalThemeAppearance? = nil

    func validate() throws {
        guard !name.isEmpty, name.count <= Self.maximumNameLength else {
            throw ICloudSettingsSyncError.invalidPayload("Theme names must contain 1...128 characters.")
        }
        guard !fontName.isEmpty, fontName.count <= Self.maximumFontNameLength else {
            throw ICloudSettingsSyncError.invalidPayload("Theme font names must contain 1...128 characters.")
        }
        guard fontSize.isFinite,
              (Double(TerminalTheme.minimumFontSize)...Double(TerminalTheme.maximumFontSize)).contains(fontSize) else {
            throw ICloudSettingsSyncError.invalidPayload("Theme font sizes must be within 10...24 points.")
        }
        guard ansiColors.count == 16 else {
            throw ICloudSettingsSyncError.invalidPayload("Terminal themes require exactly 16 ANSI colors.")
        }

        try background.validate()
        try foreground.validate()
        try cursor.validate()
        try selection.validate()
        for color in ansiColors {
            try color.validate()
        }
    }
}

/// Synchronizes the library's conflict-resolution metadata along with its
/// visual theme. Deletion tombstones are required so an offline device cannot
/// resurrect a theme that was removed elsewhere.
struct ICloudTerminalThemeRecord: Codable, Equatable, Identifiable, Sendable {
    let theme: ICloudTerminalTheme
    let origin: TerminalThemeOrigin
    let modifiedAt: Date
    let deletedAt: Date?

    var id: UUID { theme.id }
    var isDeleted: Bool { deletedAt != nil }

    func validate() throws {
        try theme.validate()
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              deletedAt?.timeIntervalSinceReferenceDate.isFinite != false else {
            throw ICloudSettingsSyncError.invalidPayload("Theme change dates must be finite.")
        }
    }
}

/// Explicit allowlist of portable, non-secret preferences. This type cannot
/// represent credentials, saved servers, host trust, SSH keys, snippets,
/// layouts, per-server overrides, recordings, or live session state.
struct ICloudPortableTerminalPreferences: Codable, Equatable, Sendable {
    var autoReconnect: Bool
    var confirmBeforeClosing: Bool
    var saveScrollback: Bool
    var maximumScrollbackLines: Int
    var bellEnabled: Bool
    var visualBell: Bool
    var cursorStyle: String
    var blinkingCursor: Bool
    var glassFrost: String
    var windowOpacity: Double
    var blurBackground: Double
    var interactiveGlass: Bool
    var glassTint: String

    func validate() throws {
        guard (0...100_000).contains(maximumScrollbackLines) else {
            throw ICloudSettingsSyncError.invalidPayload("Maximum scrollback must be within 0...100000 lines.")
        }
        guard !cursorStyle.isEmpty, cursorStyle.count <= 64 else {
            throw ICloudSettingsSyncError.invalidPayload("Cursor styles must contain 1...64 characters.")
        }
        guard !glassFrost.isEmpty, glassFrost.count <= 64 else {
            throw ICloudSettingsSyncError.invalidPayload("Glass material names must contain 1...64 characters.")
        }
        guard !glassTint.isEmpty, glassTint.count <= 64 else {
            throw ICloudSettingsSyncError.invalidPayload("Glass tint values must contain 1...64 characters.")
        }
        guard windowOpacity.isFinite, (0...1).contains(windowOpacity),
              blurBackground.isFinite, (0...1).contains(blurBackground) else {
            throw ICloudSettingsSyncError.invalidPayload("Terminal opacity and blur must be finite 0...1 values.")
        }
    }
}

struct ICloudSettingsSyncPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumThemeRecordCount = 128

    let schemaVersion: Int
    var themeRecords: [ICloudTerminalThemeRecord]
    var selectedThemeID: UUID
    var selectionModifiedAt: Date
    var preferences: ICloudPortableTerminalPreferences

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        themeRecords: [ICloudTerminalThemeRecord],
        selectedThemeID: UUID,
        selectionModifiedAt: Date,
        preferences: ICloudPortableTerminalPreferences
    ) {
        self.schemaVersion = schemaVersion
        self.themeRecords = themeRecords
        self.selectedThemeID = selectedThemeID
        self.selectionModifiedAt = selectionModifiedAt
        self.preferences = preferences
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ICloudSettingsSyncError.unsupportedPayloadSchema(schemaVersion)
        }
        guard themeRecords.count <= Self.maximumThemeRecordCount else {
            throw ICloudSettingsSyncError.invalidPayload("At most 128 terminal theme records can be synchronized.")
        }

        var themeIDs = Set<UUID>()
        var activeThemeIDs = Set<UUID>()
        var activeThemeCount = 0
        var activeBuiltInCount = 0
        for record in themeRecords {
            guard themeIDs.insert(record.id).inserted else {
                throw ICloudSettingsSyncError.invalidPayload("Terminal theme identifiers must be unique.")
            }
            try record.validate()
            if record.origin == .builtIn, record.isDeleted {
                throw ICloudSettingsSyncError.invalidPayload("The built-in terminal theme cannot be deleted.")
            }
            if record.origin == .builtIn, record.id != TerminalTheme.defaultID {
                throw ICloudSettingsSyncError.invalidPayload("The built-in terminal theme identifier is invalid.")
            }
            if !record.isDeleted {
                activeThemeIDs.insert(record.id)
                activeThemeCount += 1
                if record.origin == .builtIn { activeBuiltInCount += 1 }
            }
        }
        guard activeThemeCount <= TerminalThemeLibrary.maximumThemeCount else {
            throw ICloudSettingsSyncError.invalidPayload("At most 64 active terminal themes can be synchronized.")
        }
        guard activeBuiltInCount == 1 else {
            throw ICloudSettingsSyncError.invalidPayload("The synchronized library must contain one active built-in theme.")
        }
        guard activeThemeIDs.contains(selectedThemeID) else {
            throw ICloudSettingsSyncError.invalidPayload("The selected terminal theme must exist in the synchronized library.")
        }
        guard selectionModifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ICloudSettingsSyncError.invalidPayload("The theme selection change date must be finite.")
        }
        try preferences.validate()
    }

    /// Unions record metadata before an outgoing write. This makes a stale
    /// device retain remote tombstones instead of overwriting them merely by
    /// publishing the next envelope revision.
    func mergingThemeRecords(with other: Self) -> Self {
        var merged = Dictionary(uniqueKeysWithValues: themeRecords.map { ($0.id, $0) })
        for record in other.themeRecords {
            guard let existing = merged[record.id] else {
                merged[record.id] = record
                continue
            }
            if Self.recordIsNewer(record, than: existing) {
                merged[record.id] = record
            }
        }

        let useOtherSelection = other.selectionModifiedAt > selectionModifiedAt
            || (other.selectionModifiedAt == selectionModifiedAt
                && other.selectedThemeID.uuidString > selectedThemeID.uuidString)
        let mergedRecords = Array(merged.values)
        var resolvedSelection = useOtherSelection ? other.selectedThemeID : selectedThemeID
        let activeIDs = Set(mergedRecords.filter { !$0.isDeleted }.map(\.id))
        if !activeIDs.contains(resolvedSelection),
           let fallback = mergedRecords
            .filter({ !$0.isDeleted })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
            .first {
            resolvedSelection = fallback.id
        }
        return Self(
            themeRecords: mergedRecords,
            selectedThemeID: resolvedSelection,
            selectionModifiedAt: max(selectionModifiedAt, other.selectionModifiedAt),
            preferences: preferences
        )
    }

    private static func recordIsNewer(
        _ candidate: ICloudTerminalThemeRecord,
        than existing: ICloudTerminalThemeRecord
    ) -> Bool {
        let candidateDate = max(candidate.modifiedAt, candidate.deletedAt ?? .distantPast)
        let existingDate = max(existing.modifiedAt, existing.deletedAt ?? .distantPast)
        if candidateDate != existingDate { return candidateDate > existingDate }
        return stableRecordKey(candidate) > stableRecordKey(existing)
    }

    private static func stableRecordKey(_ record: ICloudTerminalThemeRecord) -> String {
        let theme = record.theme
        let colors = ([theme.background, theme.foreground, theme.cursor, theme.selection]
            + theme.ansiColors)
            .map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)" }
            .joined(separator: "|")
        return [
            record.origin.rawValue,
            record.deletedAt?.timeIntervalSinceReferenceDate.description ?? "",
            theme.id.uuidString,
            theme.name,
            theme.fontName,
            theme.fontSize.description,
            theme.preferredAppearance?.rawValue ?? "",
            colors,
        ].joined(separator: "|")
    }
}

struct ICloudSettingsSyncEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: UInt64
    let writerID: UUID
    let writtenAt: Date
    let payload: ICloudSettingsSyncPayload

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64,
        writerID: UUID,
        writtenAt: Date,
        payload: ICloudSettingsSyncPayload
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.writerID = writerID
        self.writtenAt = writtenAt
        self.payload = payload
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ICloudSettingsSyncError.unsupportedEnvelopeSchema(schemaVersion)
        }
        guard revision > 0 else {
            throw ICloudSettingsSyncError.invalidPayload("Sync revisions must be greater than zero.")
        }
        try payload.validate()
    }

    /// A Lamport-style revision avoids device clock skew. Concurrent writers
    /// that produce the same revision resolve by canonical UUID ordering.
    func isNewer(than other: Self) -> Bool {
        if revision != other.revision {
            return revision > other.revision
        }
        return writerID.uuidString > other.writerID.uuidString
    }
}

enum ICloudSettingsMergeResult: Equatable, Sendable {
    case noValue
    case ignored(ICloudSettingsSyncEnvelope)
    case applied(ICloudSettingsSyncEnvelope)
}

enum ICloudSettingsSyncError: LocalizedError, Equatable, Sendable {
    case disabled
    case unavailable
    case accountUnavailable
    case quotaExceeded
    case encodedValueTooLarge(actual: Int, maximum: Int)
    case unsupportedEnvelopeSchema(Int)
    case unsupportedPayloadSchema(Int)
    case invalidPayload(String)
    case revisionOverflow
    case encodingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "iCloud settings synchronization is disabled."
        case .unavailable:
            return "iCloud settings synchronization is unavailable."
        case .accountUnavailable:
            return "An iCloud account is required to synchronize terminal settings."
        case .quotaExceeded:
            return "The iCloud key-value storage quota was exceeded."
        case .encodedValueTooLarge(let actual, let maximum):
            return "The synchronized settings value is \(actual) bytes; the maximum is \(maximum) bytes."
        case .unsupportedEnvelopeSchema(let version):
            return "The iCloud settings envelope schema \(version) is not supported."
        case .unsupportedPayloadSchema(let version):
            return "The iCloud settings payload schema \(version) is not supported."
        case .invalidPayload(let reason):
            return "The iCloud settings payload is invalid: \(reason)"
        case .revisionOverflow:
            return "The iCloud settings revision counter cannot be incremented."
        case .encodingFailed(let reason):
            return "The iCloud settings payload could not be encoded: \(reason)"
        case .decodingFailed(let reason):
            return "The iCloud settings payload could not be decoded: \(reason)"
        }
    }
}

@MainActor
final class ICloudSettingsSyncService {
    typealias MergeHandler = (ICloudSettingsSyncPayload) -> Void
    typealias StatusHandler = (ICloudSettingsSyncStatus, String?) -> Void

    /// KVS permits 1 MB total. Reserving most of that quota avoids a single
    /// settings value crowding out future app metadata or server-side overhead.
    static let maximumEncodedBytes = 384 * 1024
    static let defaultStoreKey = "terminal-settings-envelope-v1"

    private let store: any ICloudSettingsKeyValueStore
    private let writerID: UUID
    private let storeKey: String
    private let maximumEncodedBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var externalChangeObserver: NSObjectProtocol?
    private var mergeHandler: MergeHandler?
    private var statusHandler: StatusHandler?
    private var isStarted = false

    private(set) var status: ICloudSettingsSyncStatus = .disabled {
        didSet { statusHandler?(status, lastErrorDescription) }
    }
    private(set) var lastErrorDescription: String?
    private(set) var acceptedEnvelope: ICloudSettingsSyncEnvelope?

    convenience init(
        writerID: UUID = UUID(),
        storeKey: String = "terminal-settings-envelope-v1",
        maximumEncodedBytes: Int = 384 * 1024
    ) {
        self.init(
            store: NSUbiquitousSettingsKeyValueStore(),
            writerID: writerID,
            storeKey: storeKey,
            maximumEncodedBytes: maximumEncodedBytes
        )
    }

    init(
        store: any ICloudSettingsKeyValueStore,
        writerID: UUID = UUID(),
        storeKey: String = "terminal-settings-envelope-v1",
        maximumEncodedBytes: Int = 384 * 1024
    ) {
        precondition(!storeKey.isEmpty && storeKey.utf16.count <= 128)
        precondition(maximumEncodedBytes > 0 && maximumEncodedBytes < 1024 * 1024)

        self.store = store
        self.writerID = writerID
        self.storeKey = storeKey
        self.maximumEncodedBytes = maximumEncodedBytes

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    isolated deinit {
        if let externalChangeObserver {
            store.removeExternalChangeObserver(externalChangeObserver)
        }
    }

    func start(
        enabled: Bool = true,
        onMerge: @escaping MergeHandler,
        onStatusChange: StatusHandler? = nil
    ) {
        stop()
        mergeHandler = onMerge
        statusHandler = onStatusChange

        guard enabled else {
            updateStatus(.disabled)
            return
        }

        isStarted = true
        externalChangeObserver = store.observeExternalChanges { [weak self] change in
            self?.handleExternalChange(change)
        }

        guard store.isAvailable else {
            updateStatus(.unavailable, error: ICloudSettingsSyncError.unavailable)
            return
        }
        guard store.isAccountAvailable else {
            updateStatus(.account, error: ICloudSettingsSyncError.accountUnavailable)
            return
        }

        updateStatus(.syncing)
        guard store.synchronize() else {
            updateStatus(.unavailable, error: ICloudSettingsSyncError.unavailable)
            return
        }
        mergeExternalValueReportingErrors()
    }

    func stop() {
        if let externalChangeObserver {
            store.removeExternalChangeObserver(externalChangeObserver)
        }
        externalChangeObserver = nil
        mergeHandler = nil
        statusHandler = nil
        isStarted = false
        lastErrorDescription = nil
        status = .disabled
    }

    @discardableResult
    func push(
        _ payload: ICloudSettingsSyncPayload,
        writtenAt: Date = Date()
    ) throws -> ICloudSettingsSyncEnvelope {
        do {
            try requireAvailableStore()
            updateStatus(.syncing)
            try payload.validate()
            let storedEnvelope = try decodeStoredEnvelopeIfPresent()
            var convergedPayload = payload
            if let acceptedEnvelope {
                convergedPayload = convergedPayload.mergingThemeRecords(with: acceptedEnvelope.payload)
            }
            if let storedEnvelope {
                convergedPayload = convergedPayload.mergingThemeRecords(with: storedEnvelope.payload)
            }
            try convergedPayload.validate()
            let latestRevision = max(
                acceptedEnvelope?.revision ?? 0,
                storedEnvelope?.revision ?? 0
            )
            guard latestRevision < UInt64.max else {
                throw ICloudSettingsSyncError.revisionOverflow
            }

            let envelope = ICloudSettingsSyncEnvelope(
                revision: latestRevision + 1,
                writerID: writerID,
                writtenAt: writtenAt,
                payload: convergedPayload
            )
            let encoded = try encode(envelope)
            store.set(encoded, forKey: storeKey)
            guard store.synchronize() else {
                throw ICloudSettingsSyncError.unavailable
            }

            acceptedEnvelope = envelope
            updateStatus(.synced)
            return envelope
        } catch {
            record(error)
            throw error
        }
    }

    /// Reads, validates, and deterministically merges the current KVS value.
    /// SettingsManager owns applying the returned allowlisted payload locally.
    @discardableResult
    func merge() throws -> ICloudSettingsMergeResult {
        do {
            try requireAvailableStore()
            updateStatus(.syncing)
            guard let candidate = try decodeStoredEnvelopeIfPresent() else {
                updateStatus(.synced)
                return .noValue
            }
            let result = merge(candidate)
            updateStatus(.synced)
            return result
        } catch {
            record(error)
            throw error
        }
    }

    /// Direct envelope merge is useful for deterministic unit tests and for
    /// future transports that deliver already-decoded values.
    @discardableResult
    func merge(_ candidate: ICloudSettingsSyncEnvelope) -> ICloudSettingsMergeResult {
        do {
            try candidate.validate()
        } catch {
            record(error)
            return .ignored(candidate)
        }

        if let acceptedEnvelope, !candidate.isNewer(than: acceptedEnvelope) {
            return .ignored(candidate)
        }

        acceptedEnvelope = candidate
        mergeHandler?(candidate.payload)
        return .applied(candidate)
    }

    private func handleExternalChange(_ change: ICloudSettingsStoreChange) {
        guard isStarted else { return }
        switch change.reason {
        case .quota:
            updateStatus(.quota, error: ICloudSettingsSyncError.quotaExceeded)
        case .account:
            // Revisions belong to one iCloud account namespace. Never compare
            // a newly signed-in account against an envelope accepted from the
            // previous account.
            acceptedEnvelope = nil
            guard store.isAccountAvailable else {
                updateStatus(.account, error: ICloudSettingsSyncError.accountUnavailable)
                return
            }
            updateStatus(.syncing)
            guard store.synchronize() else {
                updateStatus(.unavailable, error: ICloudSettingsSyncError.unavailable)
                return
            }
            mergeExternalValueReportingErrors()
        case .server, .initialSync, .unknown:
            guard change.changedKeys.isEmpty || change.changedKeys.contains(storeKey) else {
                return
            }
            mergeExternalValueReportingErrors()
        }
    }

    private func mergeExternalValueReportingErrors() {
        do {
            _ = try merge()
        } catch {
            // merge() records a stable status and public-safe error description.
        }
    }

    private func requireAvailableStore() throws {
        guard isStarted else {
            throw ICloudSettingsSyncError.disabled
        }
        guard store.isAvailable else {
            throw ICloudSettingsSyncError.unavailable
        }
        guard store.isAccountAvailable else {
            throw ICloudSettingsSyncError.accountUnavailable
        }
    }

    private func decodeStoredEnvelopeIfPresent() throws -> ICloudSettingsSyncEnvelope? {
        guard let data = store.data(forKey: storeKey) else { return nil }
        guard data.count <= maximumEncodedBytes else {
            throw ICloudSettingsSyncError.encodedValueTooLarge(
                actual: data.count,
                maximum: maximumEncodedBytes
            )
        }

        do {
            let envelope = try decoder.decode(ICloudSettingsSyncEnvelope.self, from: data)
            try envelope.validate()
            return envelope
        } catch let error as ICloudSettingsSyncError {
            throw error
        } catch {
            throw ICloudSettingsSyncError.decodingFailed(error.localizedDescription)
        }
    }

    private func encode(_ envelope: ICloudSettingsSyncEnvelope) throws -> Data {
        do {
            try envelope.validate()
            let data = try encoder.encode(envelope)
            guard data.count <= maximumEncodedBytes else {
                throw ICloudSettingsSyncError.encodedValueTooLarge(
                    actual: data.count,
                    maximum: maximumEncodedBytes
                )
            }
            return data
        } catch let error as ICloudSettingsSyncError {
            throw error
        } catch {
            throw ICloudSettingsSyncError.encodingFailed(error.localizedDescription)
        }
    }

    private func record(_ error: Error) {
        switch error {
        case ICloudSettingsSyncError.disabled:
            updateStatus(.disabled, error: error)
        case ICloudSettingsSyncError.accountUnavailable:
            updateStatus(.account, error: error)
        case ICloudSettingsSyncError.quotaExceeded:
            updateStatus(.quota, error: error)
        case ICloudSettingsSyncError.unavailable:
            updateStatus(.unavailable, error: error)
        default:
            updateStatus(.error, error: error)
        }
    }

    private func updateStatus(
        _ newStatus: ICloudSettingsSyncStatus,
        error: Error? = nil
    ) {
        lastErrorDescription = error?.localizedDescription
        status = newStatus
    }
}
