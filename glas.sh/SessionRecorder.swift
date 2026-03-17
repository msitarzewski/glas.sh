//
//  SessionRecorder.swift
//  glas.sh
//
//  Asciicast v2 format session recorder for terminal output capture
//

import Foundation
import os

// MARK: - Session Recording Model

struct SessionRecording: Identifiable, Codable {
    let id: UUID
    let sessionID: UUID
    let serverName: String
    let host: String
    let startTime: Date
    var endTime: Date?
    var eventCount: Int
    let filename: String
}

// MARK: - Session Recorder

@MainActor
@Observable
class SessionRecorder {
    private(set) var isRecording = false
    private var startTime: Date?
    private var fileHandle: FileHandle?
    private var eventCount = 0
    private var currentRecording: SessionRecording?

    func start(sessionID: UUID, serverName: String, host: String, width: Int, height: Int) {
        guard !isRecording else {
            Logger.recording.warning("Attempted to start recording while already recording")
            return
        }

        let directory = Self.recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Logger.recording.error("Failed to create recordings directory: \(error)")
            return
        }

        let filename = "\(sessionID.uuidString)_\(Self.filenameTimestamp()).cast"
        let fileURL = directory.appendingPathComponent(filename)

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            Logger.recording.error("Failed to create recording file: \(fileURL.path)")
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            self.fileHandle = handle

            let now = Date()
            self.startTime = now
            self.eventCount = 0
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
            handle.write(headerData)
            handle.write(Data("\n".utf8))

            let recording = SessionRecording(
                id: UUID(),
                sessionID: sessionID,
                serverName: serverName,
                host: host,
                startTime: now,
                endTime: nil,
                eventCount: 0,
                filename: filename
            )
            self.currentRecording = recording

            Logger.recording.info("Started recording session \(sessionID) to \(filename)")
        } catch {
            Logger.recording.error("Failed to open recording file for writing: \(error)")
            isRecording = false
            fileHandle = nil
            startTime = nil
        }
    }

    func recordOutput(_ data: Data) {
        writeEvent(data, type: "o")
    }

    func recordInput(_ data: Data) {
        writeEvent(data, type: "i")
    }

    func stop() -> SessionRecording? {
        guard isRecording, var recording = currentRecording else { return nil }

        recording.endTime = Date()
        recording.eventCount = eventCount

        fileHandle?.closeFile()
        fileHandle = nil
        isRecording = false
        startTime = nil
        eventCount = 0

        // Update index
        var recordings = Self.loadRecordings()
        recordings.append(recording)
        Self.saveRecordings(recordings)

        Logger.recording.info("Stopped recording: \(recording.filename), \(recording.eventCount) events")

        let result = recording
        currentRecording = nil
        return result
    }

    // MARK: - Private

    private func writeEvent(_ data: Data, type: String) {
        guard isRecording, let handle = fileHandle, let start = startTime else { return }

        let elapsed = Date().timeIntervalSince(start)
        let elapsedRounded = (elapsed * 1000).rounded() / 1000 // 3 decimal places
        let base64Text = data.base64EncodedString()

        // Asciicast v2 event: [elapsed, type, data]
        let line = "[\(String(format: "%.3f", elapsedRounded)),\"\(type)\",\"\(base64Text)\"]\n"
        if let lineData = line.data(using: .utf8) {
            handle.write(lineData)
            eventCount += 1
        }
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    // MARK: - Recording Index Management

    static func loadRecordings() -> [SessionRecording] {
        let indexURL = recordingsDirectory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            return try JSONDecoder().decode([SessionRecording].self, from: data)
        } catch {
            Logger.recording.error("Failed to decode recordings index: \(error)")
            return []
        }
    }

    static func saveRecordings(_ recordings: [SessionRecording]) {
        let indexURL = recordingsDirectory.appendingPathComponent("index.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(recordings)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Logger.recording.error("Failed to save recordings index: \(error)")
        }
    }

    static func deleteRecording(_ recording: SessionRecording) {
        let fileURL = recordingsDirectory.appendingPathComponent(recording.filename)
        try? FileManager.default.removeItem(at: fileURL)

        var recordings = loadRecordings()
        recordings.removeAll { $0.id == recording.id }
        saveRecordings(recordings)

        Logger.recording.info("Deleted recording: \(recording.filename)")
    }

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("recordings")
    }
}
