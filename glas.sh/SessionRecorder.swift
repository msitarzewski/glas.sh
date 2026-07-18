//
//  SessionRecorder.swift
//  glas.sh
//
//  Asciicast v2 format session recorder for terminal output capture
//

import Foundation
import os

enum BoundedStorageError: LocalizedError, Equatable {
    case sizeLimitExceeded(limit: UInt64)
    case insufficientFreeSpace(required: UInt64, available: UInt64)
    case capacityUnavailable

    var errorDescription: String? {
        switch self {
        case .sizeLimitExceeded(let limit):
            let formattedLimit = ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .file)
            return "The transfer exceeded its \(formattedLimit) storage limit."
        case .insufficientFreeSpace(let required, let available):
            let formattedRequired = ByteCountFormatter.string(fromByteCount: Int64(clamping: required), countStyle: .file)
            let formattedAvailable = ByteCountFormatter.string(fromByteCount: Int64(clamping: available), countStyle: .file)
            return "Not enough free space is available (required \(formattedRequired), available \(formattedAvailable))."
        case .capacityUnavailable:
            return "Available storage capacity could not be verified."
        }
    }
}

enum SessionRecordingStorageError: LocalizedError, Equatable {
    case invalidFilename
    case invalidRecordingIndex
    case recordingIndexTooLarge(limit: Int)
    case recordingIndexUnavailable
    case recordingIndexReadbackMismatch
    case recordingInProgress
    case deletionNotVerified(filename: String)
    case deletionRecoveryRequired(filename: String)
    case deletionRollbackFailed(filename: String)
    case maximumCountReached(limit: Int)
    case maximumAggregateBytesReached(limit: UInt64)
    case retentionReviewRequired(maximumAgeDays: Int)
    case storageAccountingUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFilename:
            return "The recording index contains an invalid file name."
        case .invalidRecordingIndex:
            return "The recording index is malformed. No recording files were changed."
        case .recordingIndexTooLarge(let limit):
            let formattedLimit = ByteCountFormatter.string(
                fromByteCount: Int64(limit),
                countStyle: .file
            )
            return "The recording index exceeds its \(formattedLimit) safety limit. No recording files were changed."
        case .recordingIndexUnavailable:
            return "The recording index could not be read safely. No recording files were changed."
        case .recordingIndexReadbackMismatch:
            return "The recording index write could not be verified."
        case .recordingInProgress:
            return "Stop the active recording before deleting it."
        case .deletionNotVerified(let filename):
            return "Deletion of \(filename) could not be verified. The incomplete recording remains listed so you can retry."
        case .deletionRecoveryRequired(let filename):
            return "Deletion of \(filename) needs recovery. Its protected bytes were quarantined without guessing whether the index committed."
        case .deletionRollbackFailed(let filename):
            return "Deletion of \(filename) could not be rolled back safely. Its protected bytes remain quarantined for recovery."
        case .maximumCountReached(let limit):
            return "The \(limit)-recording storage limit has been reached. Delete recordings before starting another."
        case .maximumAggregateBytesReached(let limit):
            let formattedLimit = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: limit),
                countStyle: .file
            )
            return "Recordings have reached their \(formattedLimit) total storage limit. Delete recordings before starting another."
        case .retentionReviewRequired(let maximumAgeDays):
            return "Recordings older than \(maximumAgeDays) days require review. Delete recordings you no longer need before starting another."
        case .storageAccountingUnavailable:
            return "Recording storage could not be verified. No new recording was started."
        }
    }
}

struct SessionRecordingStorageUsage: Equatable {
    let recordingCount: Int
    let totalBytes: UInt64
    let oldestStartTime: Date?
}

struct SessionRecordingStoragePolicy: Equatable {
    let maximumCount: Int
    let maximumAggregateBytes: UInt64
    let maximumAge: TimeInterval

    static let standard = SessionRecordingStoragePolicy(
        maximumCount: 128,
        maximumAggregateBytes: 4 * 1024 * 1024 * 1024,
        maximumAge: 90 * 24 * 60 * 60
    )

    var maximumAgeDays: Int {
        Int(maximumAge / (24 * 60 * 60))
    }
}

/// Shared storage accounting for terminal recordings and streamed file transfers.
/// All checks reserve headroom so a single operation cannot exhaust the device volume.
enum BoundedStorage {
    static let minimumFreeSpaceHeadroom: UInt64 = 256 * 1024 * 1024
    static let maximumRecordingBytes: UInt64 = 512 * 1024 * 1024
    static let maximumDownloadBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let maximumUploadBytes: UInt64 = 8 * 1024 * 1024 * 1024

    static func validateRecordingCollection(
        _ usage: SessionRecordingStorageUsage,
        now: Date,
        policy: SessionRecordingStoragePolicy = .standard
    ) throws {
        guard usage.recordingCount < policy.maximumCount else {
            throw SessionRecordingStorageError.maximumCountReached(limit: policy.maximumCount)
        }
        guard usage.totalBytes < policy.maximumAggregateBytes else {
            throw SessionRecordingStorageError.maximumAggregateBytesReached(
                limit: policy.maximumAggregateBytes
            )
        }
        if let oldestStartTime = usage.oldestStartTime,
           now.timeIntervalSince(oldestStartTime) > policy.maximumAge {
            throw SessionRecordingStorageError.retentionReviewRequired(
                maximumAgeDays: policy.maximumAgeDays
            )
        }
    }

    static func validateWrite(
        currentBytes: UInt64,
        incomingBytes: UInt64,
        maximumBytes: UInt64,
        availableCapacity: UInt64,
        headroom: UInt64 = minimumFreeSpaceHeadroom
    ) throws {
        let (nextSize, sizeOverflow) = currentBytes.addingReportingOverflow(incomingBytes)
        guard !sizeOverflow, nextSize <= maximumBytes else {
            throw BoundedStorageError.sizeLimitExceeded(limit: maximumBytes)
        }

        let (requiredCapacity, capacityOverflow) = incomingBytes.addingReportingOverflow(headroom)
        guard !capacityOverflow, availableCapacity >= requiredCapacity else {
            throw BoundedStorageError.insufficientFreeSpace(
                required: capacityOverflow ? UInt64.max : requiredCapacity,
                available: availableCapacity
            )
        }
    }

    static func availableCapacity(at url: URL) throws -> UInt64 {
        let resourceValues = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let capacity = resourceValues?.volumeAvailableCapacityForImportantUsage, capacity >= 0 {
            return UInt64(capacity)
        }
        if let capacity = resourceValues?.volumeAvailableCapacity, capacity >= 0 {
            return UInt64(capacity)
        }

        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let capacity = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value {
            return capacity
        }
        throw BoundedStorageError.capacityUnavailable
    }
}

// MARK: - Session Recording Model

struct SessionRecording: Identifiable, Codable, Equatable {
    let id: UUID
    let sessionID: UUID
    let serverName: String
    let host: String
    let startTime: Date
    var endTime: Date?
    var eventCount: Int
    let filename: String
    let capturesInput: Bool
    var isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, serverName, host, startTime, endTime, eventCount, filename
        case capturesInput, isComplete
    }

    init(
        id: UUID,
        sessionID: UUID,
        serverName: String,
        host: String,
        startTime: Date,
        endTime: Date?,
        eventCount: Int,
        filename: String,
        capturesInput: Bool,
        isComplete: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.serverName = serverName
        self.host = host
        self.startTime = startTime
        self.endTime = endTime
        self.eventCount = eventCount
        self.filename = filename
        self.capturesInput = capturesInput
        self.isComplete = isComplete
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        serverName = try values.decode(String.self, forKey: .serverName)
        host = try values.decode(String.self, forKey: .host)
        startTime = try values.decode(Date.self, forKey: .startTime)
        endTime = try values.decodeIfPresent(Date.self, forKey: .endTime)
        eventCount = try values.decode(Int.self, forKey: .eventCount)
        filename = try values.decode(String.self, forKey: .filename)
        capturesInput = try values.decodeIfPresent(Bool.self, forKey: .capturesInput) ?? false
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? (endTime != nil)
    }
}

// MARK: - Session Recorder

@MainActor
@Observable
class SessionRecorder {
    static let maximumRecordingIndexBytes = 1024 * 1024
    private struct DeletionQuarantine {
        let original: URL
        let quarantine: URL
    }

    private static var activePartialFilenames: Set<String> = []
    private static var trackedAggregateBytes: UInt64?
    private(set) static var recordingCatalogLoadError: SessionRecordingStorageError?
    private(set) var isRecording = false
    private var startTime: Date?
    private var fileHandle: FileHandle?
    private var partialFileURL: URL?
    private var eventCount = 0
    private var lastEventTime: TimeInterval = 0
    private var pendingOutputUTF8 = Data()
    private var pendingInputUTF8 = Data()
    private var currentRecording: SessionRecording?
    private var bytesWritten: UInt64 = 0
    private(set) var lastError: String?
    private let recordingsDirectoryURL: URL

    init(recordingsDirectory: URL? = nil) {
        self.recordingsDirectoryURL = recordingsDirectory ?? Self.recordingsDirectory
    }

    var capturesInput: Bool { currentRecording?.capturesInput ?? false }

    /// Begins a recording. Input capture is deliberately opt-in for each recording because
    /// terminal clients cannot reliably identify password prompts on a remote host.
    func start(
        sessionID: UUID,
        serverName: String,
        host: String,
        width: Int,
        height: Int,
        capturesInput: Bool = false
    ) {
        guard !isRecording else {
            Logger.recording.warning("Attempted to start recording while already recording")
            return
        }

        lastError = nil

        let directory = recordingsDirectoryURL
        let recordings: [SessionRecording]
        do {
            // Verify the catalog before creating a directory, partial recording,
            // or protected index. Malformed data must never become an empty list.
            recordings = try Self.verifiedRecordings(at: directory)
        } catch {
            lastError = error.localizedDescription
            Logger.recording.error(
                "Recording start refused because its index is unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            var directoryValues = URLResourceValues()
            directoryValues.isExcludedFromBackup = true
            var protectedDirectory = directory
            try protectedDirectory.setResourceValues(directoryValues)
        } catch {
            Logger.recording.error("Failed to create recordings directory: \(error)")
            lastError = error.localizedDescription
            return
        }

        do {
            let usage = Self.storageUsage(
                for: recordings,
                totalBytes: try Self.currentAggregateBytes(at: directory)
            )
            try BoundedStorage.validateRecordingCollection(usage, now: Date())
        } catch {
            lastError = error.localizedDescription
            Logger.recording.warning(
                "Recording start refused by bounded storage policy: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let recordingID = UUID()
        let filename = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
        let partialURL = directory.appendingPathComponent(".\(filename).partial")
        let now = Date()
        let recording = SessionRecording(
            id: recordingID,
            sessionID: sessionID,
            serverName: serverName,
            host: host,
            startTime: now,
            endTime: nil,
            eventCount: 0,
            filename: filename,
            capturesInput: capturesInput,
            isComplete: false
        )

        guard FileManager.default.createFile(
            atPath: partialURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            Logger.recording.error("Failed to create protected recording file")
            lastError = "The protected recording file could not be created."
            return
        }
        currentRecording = recording

        do {
            let handle = try FileHandle(forWritingTo: partialURL)
            self.fileHandle = handle
            self.partialFileURL = partialURL
            Self.activePartialFilenames.insert(filename)

            self.startTime = now
            self.eventCount = 0
            self.lastEventTime = 0
            self.pendingOutputUTF8.removeAll(keepingCapacity: true)
            self.pendingInputUTF8.removeAll(keepingCapacity: true)
            self.bytesWritten = 0
            self.isRecording = true

            // Write asciicast v2 header (line 1)
            let header: [String: Any] = [
                "version": 2,
                "width": width,
                "height": height,
                "timestamp": Int(now.timeIntervalSince1970),
                "title": "\(serverName) (\(host))"
            ]
            let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            try writeData(headerData, to: handle, at: directory)
            try writeData(Data("\n".utf8), to: handle, at: directory)

            // Persist the policy and incomplete state immediately. If the process is
            // interrupted, loadRecordings() recovers the partial file on next launch.
            var updatedRecordings = recordings
            updatedRecordings.removeAll { $0.id == recording.id }
            updatedRecordings.append(recording)
            try Self.saveRecordings(updatedRecordings, at: directory)

            Logger.recording.info("Started recording session \(sessionID) to \(filename)")
        } catch {
            Logger.recording.error("Failed to open recording file for writing: \(error)")
            lastError = error.localizedDescription
            isRecording = false
            do {
                try fileHandle?.close()
            } catch {
                Logger.recording.error(
                    "Failed to close setup-failed recording: \(error.localizedDescription, privacy: .public)"
                )
            }
            fileHandle = nil
            partialFileURL = nil
            startTime = nil
            bytesWritten = 0
            Self.activePartialFilenames.remove(filename)
            do {
                try Self.removeRecordingFile(at: partialURL)
            } catch {
                lastError = "Recording setup failed and its incomplete file could not be deleted: \(error.localizedDescription)"
                if var incomplete = currentRecording {
                    incomplete.endTime = Date()
                    incomplete.eventCount = eventCount
                    incomplete.isComplete = false
                    let retainedRecordings = Self.updatedIndex(
                        Self.loadRecordings(at: directory),
                        recording: incomplete,
                        retainRecording: true
                    )
                    do {
                        try Self.saveRecordings(retainedRecordings, at: directory)
                    } catch {
                        Logger.recording.error(
                            "Failed to retain setup-failed recording in index: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            currentRecording = nil
        }
    }

    func recordOutput(_ data: Data) {
        if let text = Self.decodeAvailableUTF8(&pendingOutputUTF8, appending: data) {
            writeTextEvent(text, type: "o")
        }
    }

    func recordInput(_ data: Data) {
        guard capturesInput else { return }
        if let text = Self.decodeAvailableUTF8(&pendingInputUTF8, appending: data) {
            writeTextEvent(text, type: "i")
        }
    }

    /// Records an asciicast v2 terminal resize event using the live dimensions.
    func recordResize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        writeTextEvent("\(width)x\(height)", type: "r")
    }

    /// Idempotently finalizes the active recording. Call this for every disconnect,
    /// remote exit, connection failure, explicit close, and application termination path.
    @discardableResult
    func finalize() -> SessionRecording? {
        stop()
    }

    func stop() -> SessionRecording? {
        guard isRecording, var recording = currentRecording else { return nil }

        flushPendingText()
        guard isRecording else { return nil }
        recording.endTime = Date()
        recording.eventCount = eventCount
        recording.isComplete = true

        var finalizationError: Error?
        var retainIncompleteAfterFailedDeletion = false
        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
        } catch {
            finalizationError = error
            recording.isComplete = false
            lastError = "Recording could not be synchronized: \(error.localizedDescription)"
            try? fileHandle?.close()
            if let partialFileURL {
                do {
                    try Self.removeRecordingFile(at: partialFileURL)
                } catch {
                    retainIncompleteAfterFailedDeletion = true
                    lastError = "Recording could not be synchronized, and its incomplete file could not be deleted: \(error.localizedDescription)"
                    Logger.recording.error(
                        "Failed to delete unsynchronized recording; retaining its index entry: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        fileHandle = nil
        isRecording = false
        startTime = nil
        eventCount = 0
        lastEventTime = 0
        pendingOutputUTF8.removeAll(keepingCapacity: true)
        pendingInputUTF8.removeAll(keepingCapacity: true)
        bytesWritten = 0

        if finalizationError == nil, let partialFileURL {
            let finalURL = recordingsDirectoryURL.appendingPathComponent(recording.filename)
            do {
                try FileManager.default.moveItem(at: partialFileURL, to: finalURL)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: finalURL.path
                )
            } catch {
                recording.isComplete = false
                lastError = "Recording could not be finalized: \(error.localizedDescription)"
                Logger.recording.error("Failed to finalize protected recording: \(error.localizedDescription, privacy: .public)")
            }
        }
        partialFileURL = nil
        Self.activePartialFilenames.remove(recording.filename)

        // Update index
        let existingRecordings = Self.loadRecordings(at: recordingsDirectoryURL)
        let finalURL = recordingsDirectoryURL.appendingPathComponent(recording.filename)
        let recoverablePartialURL = recordingsDirectoryURL.appendingPathComponent(".\(recording.filename).partial")
        let shouldRetainRecording = retainIncompleteAfterFailedDeletion
            || FileManager.default.fileExists(atPath: finalURL.path)
            || FileManager.default.fileExists(atPath: recoverablePartialURL.path)
        let recordings = Self.updatedIndex(
            existingRecordings,
            recording: recording,
            retainRecording: shouldRetainRecording
        )
        do {
            try Self.saveRecordings(recordings, at: recordingsDirectoryURL)
        } catch {
            lastError = "Recording was finalized, but its protected index could not be updated: \(error.localizedDescription)"
            Logger.recording.error("Failed to update finalized recording index: \(error.localizedDescription, privacy: .public)")
        }

        Logger.recording.info("Stopped recording: \(recording.filename), \(recording.eventCount) events")

        let result = recording
        currentRecording = nil
        return result
    }

    // MARK: - Private

    private func writeTextEvent(_ text: String, type: String) {
        guard isRecording, let handle = fileHandle, let start = startTime else { return }

        let elapsed = max(lastEventTime, Date().timeIntervalSince(start))
        let elapsedRounded = (elapsed * 1000).rounded() / 1000 // 3 decimal places
        lastEventTime = elapsedRounded

        // Asciicast v2 event: [elapsed, type, data]
        let event: [Any] = [elapsedRounded, type, text]
        do {
            let eventData = try JSONSerialization.data(withJSONObject: event)
            let newline = Data("\n".utf8)
            try writeData(eventData, to: handle, at: recordingsDirectoryURL)
            try writeData(newline, to: handle, at: recordingsDirectoryURL)
            eventCount += 1
        } catch {
            abortRecording(after: error)
        }
    }

    private func writeData(_ data: Data, to handle: FileHandle, at directory: URL) throws {
        let incomingBytes = UInt64(data.count)
        let availableCapacity = try BoundedStorage.availableCapacity(at: directory)
        try BoundedStorage.validateWrite(
            currentBytes: bytesWritten,
            incomingBytes: incomingBytes,
            maximumBytes: BoundedStorage.maximumRecordingBytes,
            availableCapacity: availableCapacity
        )
        let aggregateBytes = try Self.currentAggregateBytes(at: directory)
        try BoundedStorage.validateWrite(
            currentBytes: aggregateBytes,
            incomingBytes: incomingBytes,
            maximumBytes: SessionRecordingStoragePolicy.standard.maximumAggregateBytes,
            availableCapacity: availableCapacity
        )
        try handle.write(contentsOf: data)
        bytesWritten += incomingBytes
        Self.trackedAggregateBytes = aggregateBytes + incomingBytes
    }

    private func abortRecording(after error: Error) {
        guard var recording = currentRecording else { return }
        recording.endTime = Date()
        recording.eventCount = eventCount
        recording.isComplete = false
        lastError = error.localizedDescription
        Logger.recording.error("Recording aborted after a write failure: \(error.localizedDescription, privacy: .public)")

        try? fileHandle?.close()
        fileHandle = nil
        var deletionVerified = true
        if let partialFileURL {
            do {
                try Self.removeRecordingFile(at: partialFileURL)
            } catch {
                deletionVerified = false
                lastError = "Recording stopped, and its incomplete file could not be deleted: \(error.localizedDescription)"
                Logger.recording.error(
                    "Failed to delete aborted recording; retaining its index entry: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        Self.activePartialFilenames.remove(recording.filename)
        let recordings = Self.updatedIndex(
            Self.loadRecordings(at: recordingsDirectoryURL),
            recording: recording,
            retainRecording: !deletionVerified
        )
        do {
            try Self.saveRecordings(recordings, at: recordingsDirectoryURL)
        } catch {
            Logger.recording.error("Failed to update aborted recording index: \(error.localizedDescription, privacy: .public)")
        }

        partialFileURL = nil
        currentRecording = nil
        startTime = nil
        eventCount = 0
        lastEventTime = 0
        bytesWritten = 0
        pendingOutputUTF8.removeAll(keepingCapacity: true)
        pendingInputUTF8.removeAll(keepingCapacity: true)
        isRecording = false
    }

    private func flushPendingText() {
        if !pendingOutputUTF8.isEmpty {
            writeTextEvent(String(decoding: pendingOutputUTF8, as: UTF8.self), type: "o")
        }
        if capturesInput, !pendingInputUTF8.isEmpty {
            writeTextEvent(String(decoding: pendingInputUTF8, as: UTF8.self), type: "i")
        }
    }

    /// Test seam for fragmented terminal data. Returns all complete UTF-8 text while
    /// retaining only a potentially incomplete trailing scalar for the next chunk.
    static func decodeAvailableUTF8(_ pending: inout Data, appending data: Data) -> String? {
        pending.append(data)
        guard !pending.isEmpty else { return nil }

        let bytes = [UInt8](pending)
        var incompleteByteCount = 0
        let searchStart = max(0, bytes.count - 4)

        for index in stride(from: bytes.count - 1, through: searchStart, by: -1) {
            let byte = bytes[index]
            let expectedLength: Int?
            switch byte {
            case 0xC2...0xDF: expectedLength = 2
            case 0xE0...0xEF: expectedLength = 3
            case 0xF0...0xF4: expectedLength = 4
            case 0x00...0x7F, 0xC0...0xC1, 0xF5...0xFF: expectedLength = nil
            default: continue // Continuation byte; keep searching for its leading byte.
            }

            if let expectedLength {
                let availableLength = bytes.count - index
                let suffixIsContinuation = bytes[(index + 1)..<bytes.count].allSatisfy { (0x80...0xBF).contains($0) }
                if availableLength < expectedLength, suffixIsContinuation {
                    incompleteByteCount = availableLength
                }
            }
            break
        }

        let completeCount = bytes.count - incompleteByteCount
        guard completeCount > 0 else { return nil }
        let completeData = pending.prefix(completeCount)
        pending = Data(pending.suffix(incompleteByteCount))
        return String(decoding: completeData, as: UTF8.self)
    }

    // MARK: - Recording Index Management

    static func loadRecordings() -> [SessionRecording] {
        loadRecordings(at: recordingsDirectory)
    }

    static func loadRecordings(at directory: URL) -> [SessionRecording] {
        do {
            return try verifiedRecordings(at: directory)
        } catch {
            Logger.recording.error("Failed to load recordings index: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Loads and validates the persistent catalog before any caller is allowed to
    /// create, rename, or delete recording files. Only a verified missing index is
    /// interpreted as an empty collection.
    static func verifiedRecordings(at directory: URL) throws -> [SessionRecording] {
        do {
            var recordings = try decodedRecordingIndex(at: directory)
            try reconcileDeletionQuarantines(for: recordings, at: directory)
            var indexChanged = false

            for index in recordings.indices where !recordings[index].isComplete {
                let filename = recordings[index].filename
                guard !activePartialFilenames.contains(filename) else { continue }
                let finalURL = directory.appendingPathComponent(filename)
                let partialURL = directory.appendingPathComponent(".\(filename).partial")
                var recoveredPartial = false

                if try !verifiedItemExists(at: finalURL) {
                    guard try verifiedItemExists(at: partialURL) else { continue }
                    do {
                        try FileManager.default.moveItem(at: partialURL, to: finalURL)
                        recoveredPartial = true
                    } catch {
                        Logger.recording.error("Failed to recover interrupted recording: \(error.localizedDescription, privacy: .public)")
                        continue
                    }
                }

                do {
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: finalURL.path
                    )
                } catch {
                    Logger.recording.error("Failed to protect recovered recording: \(error.localizedDescription, privacy: .public)")
                    continue
                }

                // A crash-recovered partial has no durable completion record. It
                // remains playable evidence, but must never be represented as a
                // cleanly finalized recording. The stable file modification time
                // is only an approximate interruption time.
                if recordings[index].endTime == nil {
                    let modificationDate = try? finalURL.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                    recordings[index] = recoveredInterruptedRecording(
                        recordings[index],
                        modificationDate: modificationDate
                    )
                    indexChanged = true
                }
                if recoveredPartial {
                    Logger.recording.warning("Recovered an interrupted recording without marking it complete")
                }
            }
            if indexChanged {
                try writeRecordingsAndVerify(recordings, at: directory)
            }
            recordingCatalogLoadError = nil
            return recordings
        } catch let error as SessionRecordingStorageError {
            recordingCatalogLoadError = error
            throw error
        } catch {
            recordingCatalogLoadError = .recordingIndexUnavailable
            throw SessionRecordingStorageError.recordingIndexUnavailable
        }
    }

    private static func decodedRecordingIndex(at directory: URL) throws -> [SessionRecording] {
        let indexURL = directory.appendingPathComponent("index.json")
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        } catch {
            guard isFileNotFound(error) else {
                throw SessionRecordingStorageError.recordingIndexUnavailable
            }
            return []
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw SessionRecordingStorageError.recordingIndexUnavailable
        }
        guard size.uint64Value <= UInt64(maximumRecordingIndexBytes) else {
            throw SessionRecordingStorageError.recordingIndexTooLarge(
                limit: maximumRecordingIndexBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            throw SessionRecordingStorageError.recordingIndexUnavailable
        }
        guard data.count <= maximumRecordingIndexBytes else {
            throw SessionRecordingStorageError.recordingIndexTooLarge(
                limit: maximumRecordingIndexBytes
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recordings: [SessionRecording]
        do {
            recordings = try decoder.decode([SessionRecording].self, from: data)
        } catch {
            throw SessionRecordingStorageError.invalidRecordingIndex
        }
        guard Set(recordings.map(\.id)).count == recordings.count,
              recordings.allSatisfy({
                  isValidRecordingFilename(
                      $0.filename,
                      sessionID: $0.sessionID,
                      recordingID: $0.id
                  )
              }) else {
            throw SessionRecordingStorageError.invalidRecordingIndex
        }
        return recordings
    }

    /// Crash recovery can preserve readable bytes but cannot prove that the
    /// writer completed its final synchronization/rename transaction.
    static func recoveredInterruptedRecording(
        _ recording: SessionRecording,
        modificationDate: Date?
    ) -> SessionRecording {
        var recovered = recording
        recovered.isComplete = false
        if recovered.endTime == nil {
            recovered.endTime = max(
                recovered.startTime,
                modificationDate ?? recovered.startTime
            )
        }
        return recovered
    }

    static func saveRecordings(_ recordings: [SessionRecording]) throws {
        try saveRecordings(recordings, at: recordingsDirectory)
    }

    static func saveRecordings(_ recordings: [SessionRecording], at directory: URL) throws {
        // Preflight the existing bytes independently. A failed read or decode is
        // never permission to replace the catalog with the caller's in-memory view.
        _ = try decodedRecordingIndex(at: directory)
        try writeRecordingsAndVerify(recordings, at: directory)
    }

    private static func writeRecordingsAndVerify(
        _ recordings: [SessionRecording],
        at directory: URL
    ) throws {
        guard Set(recordings.map(\.id)).count == recordings.count,
              recordings.allSatisfy({
                  isValidRecordingFilename(
                      $0.filename,
                      sessionID: $0.sessionID,
                      recordingID: $0.id
                  )
              }) else {
            throw SessionRecordingStorageError.invalidRecordingIndex
        }
        let indexURL = directory.appendingPathComponent("index.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(recordings)
        guard data.count <= maximumRecordingIndexBytes else {
            throw SessionRecordingStorageError.recordingIndexTooLarge(
                limit: maximumRecordingIndexBytes
            )
        }
        try data.write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: indexURL.path
        )
        guard try decodedRecordingIndex(at: directory) == recordings else {
            throw SessionRecordingStorageError.recordingIndexReadbackMismatch
        }
        recordingCatalogLoadError = nil
    }

    static func deleteRecording(_ recording: SessionRecording) throws {
        try deleteRecording(recording, at: recordingsDirectory)
    }

    static func deleteRecording(_ recording: SessionRecording, at directory: URL) throws {
        try deleteRecording(
            recording,
            at: directory,
            indexWriter: { recordings, directory in
                try saveRecordings(recordings, at: directory)
            }
        )
    }

    static func deleteRecording(
        _ recording: SessionRecording,
        at directory: URL,
        indexWriter: ([SessionRecording], URL) throws -> Void
    ) throws {
        guard isValidRecordingFilename(
            recording.filename,
            sessionID: recording.sessionID,
            recordingID: recording.id
        ) else {
            throw SessionRecordingStorageError.invalidFilename
        }

        guard !activePartialFilenames.contains(recording.filename) else {
            throw SessionRecordingStorageError.recordingInProgress
        }

        // Validate before touching either the cast or partial file. This prevents
        // an unreadable index from being collapsed to [] during deletion.
        var recordings = try verifiedRecordings(at: directory)
        guard recordings.contains(where: { $0.id == recording.id }) else {
            throw SessionRecordingStorageError.invalidRecordingIndex
        }
        let originalRecordings = recordings

        let originalURLs = [
            directory.appendingPathComponent(recording.filename),
            directory.appendingPathComponent(".\(recording.filename).partial")
        ]
        let transaction = try quarantineRecordingFiles(originalURLs)

        recordings.removeAll { $0.id == recording.id }
        do {
            try indexWriter(recordings, directory)
        } catch let indexError {
            let persistedRecordings: [SessionRecording]
            do {
                persistedRecordings = try decodedRecordingIndex(at: directory)
            } catch {
                throw SessionRecordingStorageError.deletionRecoveryRequired(
                    filename: recording.filename
                )
            }

            if persistedRecordings == originalRecordings {
                do {
                    try restoreQuarantinedRecordingFiles(transaction)
                } catch {
                    throw SessionRecordingStorageError.deletionRollbackFailed(
                        filename: recording.filename
                    )
                }
                throw indexError
            }
            guard persistedRecordings == recordings else {
                throw SessionRecordingStorageError.deletionRecoveryRequired(
                    filename: recording.filename
                )
            }
        }

        do {
            for item in transaction {
                try removeRecordingFile(at: item.quarantine)
            }
        } catch {
            throw SessionRecordingStorageError.deletionRecoveryRequired(
                filename: recording.filename
            )
        }

        Logger.recording.info("Deleted recording: \(recording.filename)")
    }

    private static func quarantineRecordingFiles(
        _ originalURLs: [URL]
    ) throws -> [DeletionQuarantine] {
        var transaction: [DeletionQuarantine] = []

        do {
            for original in originalURLs {
                guard try verifiedRegularRecordingFileExists(at: original) else { continue }
                let quarantine = deletionQuarantineURL(for: original)
                guard try !verifiedItemExists(at: quarantine) else {
                    throw SessionRecordingStorageError.deletionNotVerified(
                        filename: original.lastPathComponent
                    )
                }

                try moveRecordingFileVerifying(from: original, to: quarantine)
                transaction.append(
                    DeletionQuarantine(original: original, quarantine: quarantine)
                )
            }
            return transaction
        } catch {
            do {
                try restoreQuarantinedRecordingFiles(transaction)
            } catch {
                throw SessionRecordingStorageError.deletionNotVerified(
                    filename: originalURLs.first?.lastPathComponent ?? "recording"
                )
            }
            throw error
        }
    }

    private static func restoreQuarantinedRecordingFiles(
        _ transaction: [DeletionQuarantine]
    ) throws {
        for item in transaction.reversed() {
            guard try !verifiedItemExists(at: item.original),
                  try verifiedRegularRecordingFileExists(at: item.quarantine) else {
                throw SessionRecordingStorageError.deletionNotVerified(
                    filename: item.original.lastPathComponent
                )
            }
            try moveRecordingFileVerifying(from: item.quarantine, to: item.original)
        }
    }

    private static func reconcileDeletionQuarantines(
        for recordings: [SessionRecording],
        at directory: URL
    ) throws {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            guard isFileNotFound(error) else { throw error }
            return
        }

        for quarantine in contents {
            let quarantineName = quarantine.lastPathComponent
            guard quarantineName.hasPrefix("."), quarantineName.hasSuffix(".deleting") else {
                continue
            }
            guard let originalName = deletionTransactionOriginalName(from: quarantineName) else {
                throw SessionRecordingStorageError.deletionRecoveryRequired(
                    filename: quarantineName
                )
            }
            guard try verifiedRegularRecordingFileExists(at: quarantine) else { continue }

            let original = directory.appendingPathComponent(originalName)
            let recordingFilename = originalName.hasPrefix(".")
                ? String(originalName.dropFirst().dropLast(".partial".count))
                : originalName
            let remainsIndexed = recordings.contains {
                $0.filename.caseInsensitiveCompare(recordingFilename) == .orderedSame
            }

            if remainsIndexed {
                guard try !verifiedItemExists(at: original) else {
                    throw SessionRecordingStorageError.deletionRecoveryRequired(
                        filename: recordingFilename
                    )
                }
                try moveRecordingFileVerifying(from: quarantine, to: original)
            } else {
                guard try !verifiedItemExists(at: original) else {
                    throw SessionRecordingStorageError.deletionRecoveryRequired(
                        filename: recordingFilename
                    )
                }
                do {
                    try removeRecordingFile(at: quarantine)
                } catch {
                    throw SessionRecordingStorageError.deletionRecoveryRequired(
                        filename: recordingFilename
                    )
                }
            }
        }
    }

    private static func deletionQuarantineURL(for original: URL) -> URL {
        let originalName = original.lastPathComponent
        let quarantineName = originalName.hasPrefix(".")
            ? "\(originalName).deleting"
            : ".\(originalName).deleting"
        return original.deletingLastPathComponent().appendingPathComponent(quarantineName)
    }

    private static func deletionTransactionOriginalName(
        from quarantineName: String
    ) -> String? {
        guard quarantineName.hasPrefix("."), quarantineName.hasSuffix(".deleting") else {
            return nil
        }
        let transactionName = String(
            quarantineName.dropFirst().dropLast(".deleting".count)
        )
        let recordingFilename: String
        let originalName: String
        if transactionName.hasSuffix(".cast.partial") {
            recordingFilename = String(transactionName.dropLast(".partial".count))
            originalName = ".\(transactionName)"
        } else if transactionName.hasSuffix(".cast") {
            recordingFilename = transactionName
            originalName = transactionName
        } else {
            return nil
        }
        guard isStructurallyValidRecordingFilename(recordingFilename) else { return nil }
        return originalName
    }

    private static func isStructurallyValidRecordingFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".cast") else { return false }
        let identity = filename.dropLast(".cast".count)
        let components = identity.split(separator: "_", omittingEmptySubsequences: false)
        guard components.count == 2,
              let sessionID = UUID(uuidString: String(components[0])),
              let recordingID = UUID(uuidString: String(components[1])) else { return false }
        return isValidRecordingFilename(
            filename,
            sessionID: sessionID,
            recordingID: recordingID
        )
    }

    private static func verifiedRegularRecordingFileExists(at url: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            guard isFileNotFound(error) else { throw error }
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SessionRecordingStorageError.deletionNotVerified(
                filename: url.lastPathComponent
            )
        }
        return true
    }

    private static func moveRecordingFileVerifying(from source: URL, to destination: URL) throws {
        var moveError: Error?
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            moveError = error
        }

        let sourceExists = try verifiedItemExists(at: source)
        let destinationExists = try verifiedRegularRecordingFileExists(at: destination)
        guard !sourceExists, destinationExists else {
            if let moveError { throw moveError }
            throw SessionRecordingStorageError.deletionNotVerified(
                filename: source.lastPathComponent
            )
        }
    }

    static func storageUsage(
        for recordings: [SessionRecording],
        totalBytes: UInt64
    ) -> SessionRecordingStorageUsage {
        SessionRecordingStorageUsage(
            recordingCount: recordings.count,
            totalBytes: totalBytes,
            oldestStartTime: recordings.map(\.startTime).min()
        )
    }

    static func updatedIndex(
        _ recordings: [SessionRecording],
        recording: SessionRecording,
        retainRecording: Bool
    ) -> [SessionRecording] {
        var updated = recordings
        updated.removeAll { $0.id == recording.id }
        if retainRecording {
            updated.append(recording)
        }
        return updated
    }

    /// Removes a file and verifies its absence before callers alter the protected index.
    /// A provider that reports an error after actually deleting the item is treated as
    /// successful only when the independent follow-up query proves the item is absent.
    @discardableResult
    static func removeItemVerifyingAbsence(
        at url: URL,
        itemExists: (URL) throws -> Bool,
        removeItem: (URL) throws -> Void
    ) throws -> Bool {
        guard try itemExists(url) else { return false }

        var removalError: Error?
        do {
            try removeItem(url)
        } catch {
            removalError = error
        }

        guard try !itemExists(url) else {
            if let removalError { throw removalError }
            throw SessionRecordingStorageError.deletionNotVerified(
                filename: url.lastPathComponent
            )
        }
        return true
    }

    private static func removeRecordingFile(at url: URL) throws {
        let size = try verifiedItemExists(at: url) ? try recordingFileSize(at: url) : 0
        let removed = try removeItemVerifyingAbsence(
            at: url,
            itemExists: verifiedItemExists(at:),
            removeItem: FileManager.default.removeItem(at:)
        )
        if removed, let trackedAggregateBytes {
            Self.trackedAggregateBytes = trackedAggregateBytes >= size
                ? trackedAggregateBytes - size
                : 0
        }
    }

    private static func currentAggregateBytes(at directory: URL) throws -> UInt64 {
        if let trackedAggregateBytes { return trackedAggregateBytes }

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            throw SessionRecordingStorageError.storageAccountingUnavailable
        }

        var total: UInt64 = 0
        for url in urls where isRecordingDataFile(url.lastPathComponent) {
            do {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let fileSize = values.fileSize, fileSize >= 0 else {
                    throw SessionRecordingStorageError.storageAccountingUnavailable
                }
                let (updatedTotal, overflow) = total.addingReportingOverflow(UInt64(fileSize))
                guard !overflow else {
                    throw SessionRecordingStorageError.storageAccountingUnavailable
                }
                total = updatedTotal
            } catch let error as SessionRecordingStorageError {
                throw error
            } catch {
                throw SessionRecordingStorageError.storageAccountingUnavailable
            }
        }
        trackedAggregateBytes = total
        return total
    }

    private static func isRecordingDataFile(_ filename: String) -> Bool {
        filename.hasSuffix(".cast")
            || filename.hasSuffix(".cast.partial")
            || deletionTransactionOriginalName(from: filename) != nil
    }

    private static func verifiedItemExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            if isFileNotFound(error) {
                return false
            }
            throw error
        }
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && (cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError)
    }

    private static func recordingFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw SessionRecordingStorageError.storageAccountingUnavailable
        }
        return number.uint64Value
    }

    static func isValidRecordingFilename(
        _ filename: String,
        sessionID: UUID,
        recordingID: UUID
    ) -> Bool {
        let expected = "\(sessionID.uuidString)_\(recordingID.uuidString).cast"
        return filename.caseInsensitiveCompare(expected) == .orderedSame
    }

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("recordings")
    }
}
