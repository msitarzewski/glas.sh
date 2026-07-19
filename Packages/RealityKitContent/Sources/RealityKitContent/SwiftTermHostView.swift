import SwiftUI
import Combine
import SwiftTerm
#if canImport(UIKit)
import UIKit
#if canImport(MetalKit)
import MetalKit
#endif
#elseif canImport(AppKit)
import AppKit
import Darwin
#endif

public enum SwiftTermRendererBackend: String, Equatable, Sendable {
    case awaitingWindow
    case metal
    case coreGraphics
    case coreGraphicsFallback
}

public enum SwiftTermRendererPreference: Equatable, Sendable {
    case coreGraphics
    case metal

    public static var platformDefault: Self {
        #if os(visionOS)
        // SwiftTerm's Metal view can report itself active on Vision Pro while
        // never presenting a drawable. Keep the proven UIKit renderer as the
        // device default until Metal presentation is validated independently.
        .coreGraphics
        #else
        .metal
        #endif
    }
}

public struct SwiftTermRendererDiagnostics: Equatable, Sendable {
    public let backend: SwiftTermRendererBackend
    public let isWindowAttached: Bool
    public let hostBackingIsClear: Bool?
    public let rendererBackingIsClear: Bool?
    public let failureDescription: String?

    public var preservesTransparentBacking: Bool? {
        guard let hostBackingIsClear else { return nil }
        guard hostBackingIsClear else { return false }
        guard backend == .metal else { return true }
        return rendererBackingIsClear
    }

    public static let awaitingWindow = SwiftTermRendererDiagnostics(
        backend: .awaitingWindow,
        isWindowAttached: false,
        hostBackingIsClear: nil,
        rendererBackingIsClear: nil,
        failureDescription: nil
    )
}

public struct SwiftTermPerformanceDiagnostics: Equatable, Sendable {
    public private(set) var receivedChunkCount: UInt64 = 0
    public private(set) var receivedByteCount: UInt64 = 0
    public private(set) var emittedInputChunkCount: UInt64 = 0
    public private(set) var emittedInputByteCount: UInt64 = 0
    public private(set) var totalFeedDurationNanoseconds: UInt64 = 0
    public private(set) var maximumFeedDurationNanoseconds: UInt64 = 0

    public var averageFeedDurationNanoseconds: UInt64 {
        guard receivedChunkCount > 0 else { return 0 }
        return totalFeedDurationNanoseconds / receivedChunkCount
    }

    public init() {}

    fileprivate mutating func recordFeed(byteCount: Int, duration: Duration) {
        receivedChunkCount = Self.saturatingAdd(receivedChunkCount, 1)
        receivedByteCount = Self.saturatingAdd(receivedByteCount, Self.nonnegativeUInt64(byteCount))
        let nanoseconds = Self.nanoseconds(in: duration)
        totalFeedDurationNanoseconds = Self.saturatingAdd(totalFeedDurationNanoseconds, nanoseconds)
        maximumFeedDurationNanoseconds = max(maximumFeedDurationNanoseconds, nanoseconds)
    }

    fileprivate mutating func recordInput(byteCount: Int) {
        emittedInputChunkCount = Self.saturatingAdd(emittedInputChunkCount, 1)
        emittedInputByteCount = Self.saturatingAdd(emittedInputByteCount, Self.nonnegativeUInt64(byteCount))
    }

    private static func nanoseconds(in duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        return saturatingAdd(
            saturatingMultiply(seconds, 1_000_000_000),
            attoseconds / 1_000_000_000
        )
    }

    private static func nonnegativeUInt64(_ value: Int) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private static func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : result
    }
}

/// Version 1 contains only values SwiftTerm's public delegate reports. SwiftTerm
/// 1.13 does not report OSC 133 prompt, command-boundary, or exit-status values,
/// so this schema deliberately has no cases for those unsupported semantics.
public enum SwiftTermSemanticEventKind: Equatable, Sendable {
    case workingDirectoryChanged(directory: String?)
    case fileReference(SwiftTermFileReference)
    case unhandledITermContent(command: String?, contentByteCount: Int)
    case displayRangeChanged(startY: Int, endY: Int)
    case osc52Denied(SwiftTermOSC52Decision)
}

public struct SwiftTermSemanticEvent: Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sequence: UInt64
    public let kind: SwiftTermSemanticEventKind

    public var id: UInt64 { sequence }

    fileprivate init(sequence: UInt64, kind: SwiftTermSemanticEventKind) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.kind = kind
    }
}

/// Metadata from an unhandled iTerm2 OSC 1337 `File` request. The encoded
/// payload is intentionally not retained or decoded by this event flow.
public struct SwiftTermFileReference: Equatable, Sendable {
    public let suggestedName: String?
    public let declaredByteCount: UInt64?
    public let encodedPayloadByteCount: Int
    public let requestsInlineDisplay: Bool
}

public enum SwiftTermOSC52Disposition: String, Equatable, Sendable {
    case deniedWrite
    case deniedReadQuery
    case deniedUnsupportedSelection
    case rejectedMalformed
    case rejectedOversized
}

public struct SwiftTermOSC52Decision: Equatable, Sendable {
    public static let schemaVersion = 1

    public let disposition: SwiftTermOSC52Disposition
    public let requestByteCount: Int
    public let encodedPayloadByteCount: Int?
}

public enum SwiftTermOSC52Policy {
    /// Equivalent to a maximum decoded payload of 256 KiB, including Base64 expansion.
    public static let maximumEncodedPayloadBytes = 349_528

    public static func evaluate(_ request: ArraySlice<UInt8>) -> SwiftTermOSC52Decision {
        guard request.count <= maximumEncodedPayloadBytes + 2 else {
            return decision(.rejectedOversized, request: request, payloadByteCount: nil)
        }
        guard let separator = request.firstIndex(of: UInt8(ascii: ";")) else {
            return decision(.rejectedMalformed, request: request, payloadByteCount: nil)
        }

        let selection = request[..<separator]
        let payload = request[request.index(after: separator)...]
        if payload.elementsEqual([UInt8(ascii: "?")]) {
            return decision(.deniedReadQuery, request: request, payloadByteCount: 1)
        }
        guard selection.elementsEqual([UInt8(ascii: "c")]) else {
            return decision(
                .deniedUnsupportedSelection,
                request: request,
                payloadByteCount: payload.count
            )
        }
        guard payload.count <= maximumEncodedPayloadBytes else {
            return decision(
                .rejectedOversized,
                request: request,
                payloadByteCount: payload.count
            )
        }
        guard isValidBase64(payload) else {
            return decision(
                .rejectedMalformed,
                request: request,
                payloadByteCount: payload.count
            )
        }
        return decision(.deniedWrite, request: request, payloadByteCount: payload.count)
    }

    private static func decision(
        _ disposition: SwiftTermOSC52Disposition,
        request: ArraySlice<UInt8>,
        payloadByteCount: Int?
    ) -> SwiftTermOSC52Decision {
        SwiftTermOSC52Decision(
            disposition: disposition,
            requestByteCount: request.count,
            encodedPayloadByteCount: payloadByteCount
        )
    }

    private static func isValidBase64(_ payload: ArraySlice<UInt8>) -> Bool {
        guard payload.count.isMultiple(of: 4) else { return false }
        var paddingCount = 0
        for byte in payload.reversed() where byte == UInt8(ascii: "=") {
            paddingCount += 1
        }
        guard paddingCount <= 2 else { return false }
        let dataEnd = payload.index(payload.endIndex, offsetBy: -paddingCount)
        guard payload[..<dataEnd].allSatisfy({ byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "+")
                || byte == UInt8(ascii: "/")
        }) else { return false }
        return payload[dataEnd...].allSatisfy { $0 == UInt8(ascii: "=") }
    }
}

public enum SwiftTermITermContentPolicy {
    public static let maximumSuggestedNameBytes = 4_096
    public static let maximumMetadataBytes = 16_384

    public static func semanticEventKind(
        for content: ArraySlice<UInt8>
    ) -> SwiftTermSemanticEventKind {
        let contentByteCount = content.count
        let metadataPrefix = content.prefix(maximumMetadataBytes + 1)
        guard let colonIndex = metadataPrefix.firstIndex(of: UInt8(ascii: ":")),
              content.distance(from: content.startIndex, to: colonIndex) <= maximumMetadataBytes else {
            return .unhandledITermContent(
                command: commandName(in: content),
                contentByteCount: contentByteCount
            )
        }

        let header = content[..<colonIndex]
        guard header.starts(with: Array("File=".utf8)) else {
            return .unhandledITermContent(
                command: commandName(in: header),
                contentByteCount: contentByteCount
            )
        }

        let optionBytes = header.dropFirst("File=".utf8.count)
        guard let optionString = String(bytes: optionBytes, encoding: .utf8) else {
            return .unhandledITermContent(
                command: "File",
                contentByteCount: contentByteCount
            )
        }
        let options = optionString
            .split(separator: ";", omittingEmptySubsequences: true)
            .reduce(into: [String: String]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = String(pair[1])
            }

        return .fileReference(
            SwiftTermFileReference(
                suggestedName: decodedSuggestedName(options["name"]),
                declaredByteCount: options["size"].flatMap(UInt64.init),
                encodedPayloadByteCount: content.distance(
                    from: content.index(after: colonIndex),
                    to: content.endIndex
                ),
                requestsInlineDisplay: options["inline"] == "1"
            )
        )
    }

    private static func commandName(in content: ArraySlice<UInt8>) -> String? {
        let boundedPrefix = content.prefix(65)
        let boundary = boundedPrefix.firstIndex { byte in
            byte == UInt8(ascii: "=") || byte == UInt8(ascii: ";") || byte == UInt8(ascii: ":")
        } ?? boundedPrefix.endIndex
        let bytes = boundedPrefix[..<boundary]
        guard !bytes.isEmpty, bytes.count <= 64,
              let command = String(bytes: bytes, encoding: .utf8) else { return nil }
        return command
    }

    private static func decodedSuggestedName(_ value: String?) -> String? {
        guard let value,
              let encoded = value.data(using: .utf8),
              encoded.count <= maximumSuggestedNameBytes * 2,
              let decoded = Data(base64Encoded: encoded),
              !decoded.isEmpty,
              decoded.count <= maximumSuggestedNameBytes,
              let name = String(data: decoded, encoding: .utf8),
              !name.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      return true
                  default:
                      return false
                  }
              }) else { return nil }
        return name
    }
}

@MainActor
public final class SwiftTermHostModel: ObservableObject {
    public static let semanticEventHistoryLimit = 256

    @Published public private(set) var currentDirectory: String?
    @Published public private(set) var scrollPosition: Double = 1
    @Published public private(set) var pendingPasteReview: SwiftTermPasteReview?
    @Published public private(set) var pendingExternalLink: SwiftTermExternalLinkRequest?
    public private(set) var rendererDiagnostics = SwiftTermRendererDiagnostics.awaitingWindow
    public private(set) var semanticEvents: [SwiftTermSemanticEvent] = []
    public let semanticEventPublisher = PassthroughSubject<SwiftTermSemanticEvent, Never>()
    private weak var terminalEngine: (any TerminalEngine)?
    private var attachedViewID: ObjectIdentifier?
    private var pendingChunks: [Data] = []
    private var lastNonce: UInt64 = 0
    private var focusRetryTask: Task<Void, Never>?
    private var focusOwnershipAllowed = true
    private var nextSemanticEventSequence: UInt64 = 1

    public init() {}

    fileprivate func attach(_ engine: any TerminalEngine) {
        let viewID = engine.identity
        guard attachedViewID != viewID else {
            return
        }
        terminalEngine = engine
        attachedViewID = viewID
        publishRendererDiagnosticsIfChanged(engine.rendererDiagnostics)
        flushPending()
        focus()
    }

    fileprivate func updateRendererDiagnostics(_ diagnostics: SwiftTermRendererDiagnostics) {
        publishRendererDiagnosticsIfChanged(diagnostics)
    }

    private func publishRendererDiagnosticsIfChanged(
        _ diagnostics: SwiftTermRendererDiagnostics
    ) {
        guard rendererDiagnostics != diagnostics else { return }
        rendererDiagnostics = diagnostics
    }

    public func focus() {
        guard focusOwnershipAllowed else {
            stopFocusMaintenance()
            return
        }
        focusRetryTask?.cancel()
        focusRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // First responder can fail transiently during window activation;
            // retry briefly, but only while this terminal's window is active.
            // Focus is otherwise driven explicitly by the host UI so sheets,
            // search fields, alerts, and IME composition retain ownership.
            for _ in 0..<3 {
                guard self.focusOwnershipAllowed,
                      let engine = self.terminalEngine else { return }
                if engine.focusIfActive() {
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    public func setFocusOwnershipAllowed(_ allowed: Bool) {
        focusOwnershipAllowed = allowed
        if allowed {
            focus()
        } else {
            stopFocusMaintenance()
            terminalEngine?.resignFocus()
        }
    }

    public func stopFocusMaintenance() {
        focusRetryTask?.cancel()
        focusRetryTask = nil
    }

    public var isLikelyRunningInteractiveProgram: Bool {
        terminalEngine?.isLikelyRunningInteractiveProgram ?? false
    }

    public var isComposingText: Bool {
        terminalEngine?.isComposingText ?? false
    }

    public var performanceDiagnostics: SwiftTermPerformanceDiagnostics {
        terminalEngine?.performanceDiagnostics ?? SwiftTermPerformanceDiagnostics()
    }

    public func getVisibleText(lastNLines: Int = 20) -> [String] {
        terminalEngine?.visibleText(lastNLines: lastNLines) ?? []
    }

    @discardableResult
    public func findNext(_ term: String) -> Bool {
        guard !term.isEmpty else {
            clearSearch()
            return false
        }
        return terminalEngine?.findNext(term) ?? false
    }

    @discardableResult
    public func findPrevious(_ term: String) -> Bool {
        guard !term.isEmpty else {
            clearSearch()
            return false
        }
        return terminalEngine?.findPrevious(term) ?? false
    }

    public func clearSearch() {
        terminalEngine?.clearSearch()
    }

    public func resolvePendingPaste(approvedText: String?) {
        guard let request = pendingPasteReview else { return }
        pendingPasteReview = nil
        guard let approvedText,
              SwiftTermPastePolicy.isAllowed(approvedText) else { return }
        terminalEngine?.commitPaste(approvedText, bracketed: request.bracketedPasteMode)
    }

    public func resolvePendingExternalLink(approved: Bool) -> URL? {
        guard let request = pendingExternalLink else { return nil }
        pendingExternalLink = nil
        return approved ? request.url : nil
    }

    fileprivate func requestPaste(_ text: String, bracketed: Bool) {
        guard pendingPasteReview == nil, !text.isEmpty else { return }
        if let review = SwiftTermPastePolicy.reviewRequest(for: text, bracketed: bracketed) {
            pendingPasteReview = review
        } else if SwiftTermPastePolicy.isAllowed(text) {
            terminalEngine?.commitPaste(text, bracketed: bracketed)
        }
    }

    fileprivate func requestExternalLink(_ link: String) {
        guard pendingExternalLink == nil,
              let request = SwiftTermExternalLinkPolicy.validatedRequest(for: link) else {
            return
        }
        pendingExternalLink = request
    }

    fileprivate func updateCurrentDirectory(_ directory: String?) {
        currentDirectory = directory
        appendSemanticEvent(.workingDirectoryChanged(directory: directory))
    }

    fileprivate func updateScrollPosition(_ position: Double) {
        scrollPosition = min(1, max(0, position))
    }

    fileprivate func recordITermEvent(_ kind: SwiftTermSemanticEventKind) {
        appendSemanticEvent(kind)
    }

    fileprivate func recordDisplayRange(startY: Int, endY: Int) {
        appendSemanticEvent(.displayRangeChanged(startY: startY, endY: endY))
    }

    fileprivate func recordOSC52Decision(_ decision: SwiftTermOSC52Decision) {
        appendSemanticEvent(.osc52Denied(decision))
    }

    private func appendSemanticEvent(_ kind: SwiftTermSemanticEventKind) {
        let event = SwiftTermSemanticEvent(sequence: nextSemanticEventSequence, kind: kind)
        semanticEvents.append(event)
        nextSemanticEventSequence += 1
        if semanticEvents.count > Self.semanticEventHistoryLimit {
            semanticEvents.removeFirst(semanticEvents.count - Self.semanticEventHistoryLimit)
        }
        semanticEventPublisher.send(event)
    }

    public func ingest(data: Data, nonce: UInt64) {
        guard nonce != lastNonce else { return }
        lastNonce = nonce
        pendingChunks.append(data)
        flushPending()
    }

    private func flushPending() {
        guard let terminalEngine else { return }
        for chunk in pendingChunks {
            terminalEngine.receive(chunk)
        }
        pendingChunks.removeAll(keepingCapacity: true)
    }
}

public struct SwiftTermExternalLinkRequest: Identifiable, Equatable {
    public let id: UUID
    public let url: URL
    public let normalizedHost: String
    public let port: Int?

    public var exactURL: String { url.absoluteString }

    fileprivate init(
        id: UUID = UUID(),
        url: URL,
        normalizedHost: String,
        port: Int?
    ) {
        self.id = id
        self.url = url
        self.normalizedHost = normalizedHost
        self.port = port
    }
}

public enum SwiftTermExternalLinkPolicy {
    public static let maximumURLBytes = 8_192

    private static func containsUnsafeDisplayScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                return true
            default:
                return false
            }
        }
    }

    public static func validatedRequest(for link: String) -> SwiftTermExternalLinkRequest? {
        guard !link.isEmpty,
              link.utf8.count <= maximumURLBytes,
              link == link.trimmingCharacters(in: .whitespacesAndNewlines),
              !link.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format:
                      return true
                  default:
                      return false
                  }
              }),
              var components = URLComponents(string: link),
              let rawScheme = components.scheme,
              ["http", "https"].contains(rawScheme.lowercased()),
              components.user == nil,
              components.password == nil,
              let rawHost = components.host,
              !rawHost.isEmpty,
              !containsUnsafeDisplayScalar(rawHost) else {
            return nil
        }

        components.scheme = rawScheme.lowercased()
        guard let url = components.url,
              let normalizedURLHost = url.host?.lowercased(),
              !normalizedURLHost.isEmpty,
              !containsUnsafeDisplayScalar(normalizedURLHost) else {
            return nil
        }

        return SwiftTermExternalLinkRequest(
            url: url,
            normalizedHost: normalizedURLHost,
            port: components.port
        )
    }
}

public struct SwiftTermPasteReview: Identifiable, Equatable {
    public let id: UUID
    public let content: String
    public let byteCount: Int
    public let lineCount: Int
    public let bracketedPasteMode: Bool
    public let exceedsMaximumSize: Bool
}

public enum SwiftTermPastePolicy {
    public static let directPasteMaximumBytes = 4_096
    public static let maximumPayloadBytes = 262_144
    private static let bracketedPasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    private static let bracketedPasteEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])

    public static func isAllowed(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumPayloadBytes
    }

    public static func requiresReview(_ text: String) -> Bool {
        text.contains("\n")
            || text.contains("\r")
            || text.utf8.count > directPasteMaximumBytes
    }

    public static func reviewRequest(
        for text: String,
        bracketed: Bool
    ) -> SwiftTermPasteReview? {
        guard requiresReview(text) || !isAllowed(text) else { return nil }
        let byteCount = text.utf8.count
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return SwiftTermPasteReview(
            id: UUID(),
            content: byteCount <= maximumPayloadBytes ? text : "",
            byteCount: byteCount,
            lineCount: normalized.split(separator: "\n", omittingEmptySubsequences: false).count,
            bracketedPasteMode: bracketed,
            exceedsMaximumSize: byteCount > maximumPayloadBytes
        )
    }

    public static func framedData(for text: String, bracketed: Bool) -> Data {
        var data = Data()
        if bracketed {
            data.append(bracketedPasteStart)
        }
        data.append(Data(text.utf8))
        if bracketed {
            data.append(bracketedPasteEnd)
        }
        return data
    }
}

public struct SwiftTermThemeColor: Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct SwiftTermTheme: Equatable {
    public var fontSize: CGFloat
    public var fontName: String
    public var foreground: (red: Double, green: Double, blue: Double)
    public var background: (red: Double, green: Double, blue: Double, alpha: Double)
    public var cursor: (red: Double, green: Double, blue: Double)
    public var selection: (red: Double, green: Double, blue: Double, alpha: Double)
    public var ansiColors: [SwiftTermThemeColor]

    public init(
        fontSize: CGFloat,
        foreground: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double, alpha: Double),
        cursor: (red: Double, green: Double, blue: Double),
        fontName: String = "SF Mono",
        selection: (red: Double, green: Double, blue: Double, alpha: Double) = (0, 0.48, 1, 0.3),
        ansiColors: [SwiftTermThemeColor] = []
    ) {
        self.fontSize = fontSize
        self.fontName = fontName
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansiColors = ansiColors
    }

    public static func == (lhs: SwiftTermTheme, rhs: SwiftTermTheme) -> Bool {
        lhs.fontSize == rhs.fontSize
            && lhs.fontName == rhs.fontName
            && lhs.foreground == rhs.foreground
            && lhs.background == rhs.background
            && lhs.cursor == rhs.cursor
            && lhs.selection == rhs.selection
            && lhs.ansiColors == rhs.ansiColors
    }
}

public struct SwiftTermRuntimeSettings: Equatable {
    public var cursorStyle: String
    public var blinkingCursor: Bool
    public var scrollbackLines: Int
    public var optionAsMetaKey: Bool

    public init(
        cursorStyle: String,
        blinkingCursor: Bool,
        scrollbackLines: Int,
        optionAsMetaKey: Bool = false
    ) {
        self.cursorStyle = cursorStyle
        self.blinkingCursor = blinkingCursor
        self.scrollbackLines = min(100_000, max(0, scrollbackLines))
        self.optionAsMetaKey = optionAsMetaKey
    }
}

/// Narrow boundary between terminal transport/state and the concrete renderer.
/// The active implementation remains SwiftTerm; an alternate renderer only needs to
/// conform here and be selected by `SwiftTermHostView.makeEngine`.
#if canImport(UIKit)
@MainActor
private protocol TerminalEngine: AnyObject {
    var identity: ObjectIdentifier { get }
    var hostView: UIView { get }
    var isLikelyRunningInteractiveProgram: Bool { get }
    var isComposingText: Bool { get }
    var rendererDiagnostics: SwiftTermRendererDiagnostics { get }
    var performanceDiagnostics: SwiftTermPerformanceDiagnostics { get }

    func configure(theme: SwiftTermTheme, runtimeSettings: SwiftTermRuntimeSettings)
    func receive(_ data: Data)
    func recordInput(byteCount: Int)
    func focusIfActive() -> Bool
    func resignFocus()
    func refreshAccessibilityViewport()
    func visibleText(lastNLines: Int) -> [String]
    func findNext(_ term: String) -> Bool
    func findPrevious(_ term: String) -> Bool
    func clearSearch()
    func commitPaste(_ text: String, bracketed: Bool)
}

public enum SwiftTermHardwareKeyPolicy {
    /// SwiftTerm's legacy input path maps F10 to F9 and drops F12-F24. Keep
    /// Kitty protocol handling in SwiftTerm, but provide the standard xterm
    /// sequences when the remote has not enabled Kitty keyboard reporting.
    public static func legacyFunctionKeySequence(for keyCode: UIKeyboardHIDUsage) -> [UInt8]? {
        switch keyCode {
        case .keyboardF10:
            return EscapeSequences.cmdF[9]
        case .keyboardF12:
            return EscapeSequences.cmdF[11]
        case .keyboardF13:
            return csiTilde(25)
        case .keyboardF14:
            return csiTilde(26)
        case .keyboardF15:
            return csiTilde(28)
        case .keyboardF16:
            return csiTilde(29)
        case .keyboardF17:
            return csiTilde(31)
        case .keyboardF18:
            return csiTilde(32)
        case .keyboardF19:
            return csiTilde(33)
        case .keyboardF20:
            return csiTilde(34)
        case .keyboardF21:
            return csiTilde(42)
        case .keyboardF22:
            return csiTilde(43)
        case .keyboardF23:
            return csiTilde(44)
        case .keyboardF24:
            return csiTilde(45)
        default:
            return nil
        }
    }

    private static func csiTilde(_ number: Int) -> [UInt8] {
        Array("\u{1B}[\(number)~".utf8)
    }
}

@MainActor
private final class ReviewingTerminalView: TerminalView {
    var onPasteRequest: ((String, Bool) -> Void)?
    var onWindowAttachmentChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowAttachmentChanged?()
    }

    @objc override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onPasteRequest?(text, getTerminal().bracketedPasteMode)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(correctedFunctionKeyCommand(input: UIKeyCommand.f10))
        commands.append(correctedFunctionKeyCommand(input: UIKeyCommand.f12))
        return commands
    }

    private func correctedFunctionKeyCommand(input: String) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: [],
            action: #selector(sendCorrectedFunctionKey(_:))
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func sendCorrectedFunctionKey(_ command: UIKeyCommand) {
        let keyCode: UIKeyboardHIDUsage
        switch command.input {
        case UIKeyCommand.f10: keyCode = .keyboardF10
        case UIKeyCommand.f12: keyCode = .keyboardF12
        default: return
        }
        _ = sendLegacyFunctionKeyIfEligible(keyCode)
    }

    /// Sends only legacy function keys SwiftTerm does not encode
    /// correctly. Marked text belongs to UIKit's input method, while Kitty
    /// keyboard mode remains wholly owned by SwiftTerm.
    fileprivate func sendLegacyFunctionKeyIfEligible(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        guard markedTextRange == nil,
              getTerminal().keyboardEnhancementFlags.isEmpty,
              let bytes = SwiftTermHardwareKeyPolicy.legacyFunctionKeySequence(for: keyCode)
        else { return false }
        terminalDelegate?.send(source: self, data: bytes[...])
        return true
    }
}

/// SwiftTerm's iOS `pressesBegan` override is public but not open, so a
/// subclass cannot repair its legacy F13-F24 handling. Those keys are left
/// unhandled and forwarded through the public UIResponder chain; this parent
/// consumes just those events after SwiftTerm has declined them.
@MainActor
private final class TerminalHardwareKeyContainerView: UIView {
    weak var terminalView: ReviewingTerminalView?

    override func layoutSubviews() {
        super.layoutSubviews()
        terminalView?.frame = bounds
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandledPresses = presses
        for press in presses {
            guard let keyCode = press.key?.keyCode,
                  keyCode.rawValue >= UIKeyboardHIDUsage.keyboardF13.rawValue,
                  keyCode.rawValue <= UIKeyboardHIDUsage.keyboardF24.rawValue,
                  terminalView?.sendLegacyFunctionKeyIfEligible(keyCode) == true
            else { continue }
            unhandledPresses.remove(press)
        }

        if !unhandledPresses.isEmpty {
            super.pressesBegan(unhandledPresses, with: event)
        }
    }
}

@MainActor
private final class SwiftTermEngine: TerminalEngine {
    let terminalView: ReviewingTerminalView
    private let containerView: TerminalHardwareKeyContainerView
    private let onPasteData: (Data) -> Void
    private let onRendererDiagnostics: (SwiftTermRendererDiagnostics) -> Void
    private let onOSC52Decision: (SwiftTermOSC52Decision) -> Void
    private let performanceClock = ContinuousClock()
    private let rendererPreference = SwiftTermRendererPreference.platformDefault
    private var metalActivationAttempted = false
    private var configuredTheme: SwiftTermTheme?
    private(set) var rendererDiagnostics = SwiftTermRendererDiagnostics.awaitingWindow
    private(set) var performanceDiagnostics = SwiftTermPerformanceDiagnostics()

    init(
        delegate: TerminalViewDelegate,
        onPasteRequest: @escaping (String, Bool) -> Void,
        onPasteData: @escaping (Data) -> Void,
        onRendererDiagnostics: @escaping (SwiftTermRendererDiagnostics) -> Void,
        onOSC52Decision: @escaping (SwiftTermOSC52Decision) -> Void
    ) {
        let terminalView = ReviewingTerminalView(frame: .zero)
        let containerView = TerminalHardwareKeyContainerView(frame: .zero)
        terminalView.terminalDelegate = delegate
        terminalView.onPasteRequest = onPasteRequest
        terminalView.notifyUpdateChanges = true
        terminalView.isOpaque = false
        terminalView.backgroundColor = .clear
        terminalView.clearsContextBeforeDrawing = false
        terminalView.layer.cornerRadius = 18
        terminalView.layer.masksToBounds = true
        terminalView.isAccessibilityElement = true
        terminalView.accessibilityLabel = "Terminal"
        terminalView.accessibilityHint = "Double-tap to enter terminal input."
        terminalView.accessibilityTraits.insert(.updatesFrequently)
        terminalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.isOpaque = false
        containerView.backgroundColor = .clear
        containerView.terminalView = terminalView
        containerView.addSubview(terminalView)
        self.terminalView = terminalView
        self.containerView = containerView
        self.onPasteData = onPasteData
        self.onRendererDiagnostics = onRendererDiagnostics
        self.onOSC52Decision = onOSC52Decision
        terminalView.onWindowAttachmentChanged = { [weak self] in
            self?.activateRendererIfAttached()
        }
        terminalView.getTerminal().parser.oscHandlers[52] = { [weak self] request in
            guard let self else { return }
            self.onOSC52Decision(SwiftTermOSC52Policy.evaluate(request))
        }
    }

    var identity: ObjectIdentifier { ObjectIdentifier(terminalView) }
    var hostView: UIView { containerView }
    var isLikelyRunningInteractiveProgram: Bool {
        terminalView.getTerminal().isCurrentBufferAlternate
    }
    var isComposingText: Bool { terminalView.markedTextRange != nil }

    func configure(theme: SwiftTermTheme, runtimeSettings: SwiftTermRuntimeSettings) {
        configuredTheme = theme
        applyTheme(theme)
        applyRuntimeSettings(runtimeSettings)
        activateRendererIfAttached()
    }

    func receive(_ data: Data) {
        let start = performanceClock.now
        terminalView.feed(byteArray: ArraySlice(data))
        performanceDiagnostics.recordFeed(
            byteCount: data.count,
            duration: start.duration(to: performanceClock.now)
        )
        refreshAccessibilityValue()
    }

    func recordInput(byteCount: Int) {
        performanceDiagnostics.recordInput(byteCount: byteCount)
    }

    func refreshAccessibilityViewport() {
        refreshAccessibilityValue()
    }

    func focusIfActive() -> Bool {
        guard let window = terminalView.window, window.isKeyWindow else { return false }
        if terminalView.isFirstResponder {
            applyConfiguredCaretTheme()
            return true
        }
        guard !isComposingText else { return false }
        let focused = terminalView.becomeFirstResponder()
        if focused {
            // SwiftTerm creates its iOS caret view while becoming first responder.
            // The initial pre-attachment theme assignment therefore cannot color
            // the caret and must be replayed after focus is established.
            applyConfiguredCaretTheme()
        }
        return focused
    }

    func resignFocus() {
        guard terminalView.isFirstResponder else { return }
        _ = terminalView.resignFirstResponder()
    }

    func visibleText(lastNLines: Int) -> [String] {
        let buffer = terminalView.getTerminal().getBufferAsData()
        let fullText = String(data: buffer, encoding: .utf8) ?? ""
        let allLines = fullText.components(separatedBy: "\n")
        let nonEmpty = allLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(nonEmpty.suffix(max(0, lastNLines)))
    }

    func findNext(_ term: String) -> Bool { terminalView.findNext(term) }
    func findPrevious(_ term: String) -> Bool { terminalView.findPrevious(term) }
    func clearSearch() { terminalView.clearSearch() }
    func commitPaste(_ text: String, bracketed: Bool) {
        let data = SwiftTermPastePolicy.framedData(for: text, bracketed: bracketed)
        recordInput(byteCount: data.count)
        onPasteData(data)
    }

    private func refreshAccessibilityValue() {
        let terminal = terminalView.getTerminal()
        let maximumLines = 40
        let maximumCharacters = 4_096
        let firstRow = max(0, terminal.rows - maximumLines)
        var remainingCharacters = maximumCharacters
        var visibleLines: [String] = []
        visibleLines.reserveCapacity(min(maximumLines, terminal.rows))

        for row in firstRow..<terminal.rows where remainingCharacters > 0 {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }
            )
            guard !text.isEmpty else { continue }
            let boundedText = String(text.prefix(remainingCharacters))
            visibleLines.append(boundedText)
            remainingCharacters -= boundedText.count
        }

        terminalView.accessibilityValue = visibleLines.isEmpty
            ? "No visible output"
            : visibleLines.joined(separator: "\n")
    }

    private func activateRendererIfAttached() {
        enforceClearBacking()

        guard terminalView.window != nil else {
            #if canImport(MetalKit)
            let detachedBackend: SwiftTermRendererBackend = terminalView.isUsingMetalRenderer
                ? .metal
                : .awaitingWindow
            #else
            let detachedBackend: SwiftTermRendererBackend = .awaitingWindow
            #endif
            publishRendererDiagnostics(
                backend: detachedBackend,
                failureDescription: rendererDiagnostics.failureDescription
            )
            return
        }

        #if canImport(MetalKit)
        if rendererPreference == .coreGraphics {
            if terminalView.isUsingMetalRenderer {
                do {
                    try terminalView.setUseMetal(false)
                } catch {
                    publishRendererDiagnostics(
                        backend: .coreGraphicsFallback,
                        failureDescription: String(describing: error)
                    )
                    return
                }
            }
            enforceClearBacking()
            publishRendererDiagnostics(backend: .coreGraphics, failureDescription: nil)
            return
        }

        if !terminalView.isUsingMetalRenderer && !metalActivationAttempted {
            metalActivationAttempted = true
            do {
                try terminalView.setUseMetal(true)
            } catch {
                enforceClearBacking()
                publishRendererDiagnostics(
                    backend: .coreGraphicsFallback,
                    failureDescription: String(describing: error)
                )
                return
            }
        }

        enforceClearBacking()
        publishRendererDiagnostics(
            backend: terminalView.isUsingMetalRenderer ? .metal : .coreGraphicsFallback,
            failureDescription: terminalView.isUsingMetalRenderer
                ? nil
                : "SwiftTerm did not activate its Metal renderer."
        )
        #else
        publishRendererDiagnostics(
            backend: .coreGraphicsFallback,
            failureDescription: "MetalKit is unavailable on this platform."
        )
        #endif
    }

    private func enforceClearBacking() {
        terminalView.isOpaque = false
        terminalView.backgroundColor = .clear
        terminalView.layer.backgroundColor = UIColor.clear.cgColor

        #if canImport(MetalKit)
        for metalView in terminalView.subviews.compactMap({ $0 as? MTKView }) {
            metalView.isOpaque = false
            metalView.backgroundColor = .clear
            metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
            (metalView.layer as? CAMetalLayer)?.isOpaque = false
        }
        #endif
    }

    private func publishRendererDiagnostics(
        backend: SwiftTermRendererBackend,
        failureDescription: String?
    ) {
        #if canImport(MetalKit)
        let metalViews = terminalView.subviews.compactMap { $0 as? MTKView }
        let rendererBackingIsClear: Bool? = metalViews.isEmpty
            ? nil
            : metalViews.allSatisfy { metalView in
                !metalView.isOpaque
                    && Self.alpha(of: metalView.backgroundColor) == 0
                    && metalView.clearColor.alpha == 0
                    && (metalView.layer as? CAMetalLayer)?.isOpaque == false
            }
        #else
        let rendererBackingIsClear: Bool? = nil
        #endif

        let diagnostics = SwiftTermRendererDiagnostics(
            backend: backend,
            isWindowAttached: terminalView.window != nil,
            hostBackingIsClear: !terminalView.isOpaque
                && Self.alpha(of: terminalView.backgroundColor) == 0
                && Self.alpha(of: terminalView.layer.backgroundColor) == 0
                && Self.alpha(of: terminalView.nativeBackgroundColor) == 0,
            rendererBackingIsClear: rendererBackingIsClear,
            failureDescription: failureDescription
        )
        rendererDiagnostics = diagnostics
        onRendererDiagnostics(diagnostics)
    }

    private static func alpha(of color: UIColor?) -> CGFloat {
        color?.cgColor.alpha ?? 0
    }

    private static func alpha(of color: CGColor?) -> CGFloat {
        color?.alpha ?? 0
    }

    private func applyTheme(_ theme: SwiftTermTheme) {
        let fontSize = max(10, theme.fontSize)
        if theme.fontName == "SF Mono" {
            terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        } else {
            terminalView.font = UIFont(name: theme.fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        terminalView.nativeForegroundColor = UIColor(
            red: theme.foreground.red,
            green: theme.foreground.green,
            blue: theme.foreground.blue,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = UIColor(
            red: theme.background.red,
            green: theme.background.green,
            blue: theme.background.blue,
            alpha: theme.background.alpha
        )
        enforceClearBacking()
        terminalView.caretColor = UIColor(
            red: theme.cursor.red,
            green: theme.cursor.green,
            blue: theme.cursor.blue,
            alpha: 1
        )
        terminalView.selectedTextBackgroundColor = UIColor(
            red: theme.selection.red,
            green: theme.selection.green,
            blue: theme.selection.blue,
            alpha: theme.selection.alpha
        )
        if theme.ansiColors.count == 16 {
            terminalView.installColors(theme.ansiColors.map { color in
                SwiftTerm.Color(
                    red: Self.terminalColorComponent(color.red),
                    green: Self.terminalColorComponent(color.green),
                    blue: Self.terminalColorComponent(color.blue)
                )
            })
        }
    }

    private func applyConfiguredCaretTheme() {
        guard let theme = configuredTheme else { return }
        terminalView.caretColor = UIColor(
            red: theme.cursor.red,
            green: theme.cursor.green,
            blue: theme.cursor.blue,
            alpha: 1
        )
    }

    private static func terminalColorComponent(_ component: Double) -> UInt16 {
        UInt16((min(1, max(0, component)) * Double(UInt16.max)).rounded())
    }

    private func applyRuntimeSettings(_ settings: SwiftTermRuntimeSettings) {
        let normalizedStyle = settings.cursorStyle.lowercased()
        let cursorStyle: CursorStyle
        switch (normalizedStyle, settings.blinkingCursor) {
        case ("underline", true): cursorStyle = .blinkUnderline
        case ("underline", false): cursorStyle = .steadyUnderline
        case ("bar", true): cursorStyle = .blinkBar
        case ("bar", false): cursorStyle = .steadyBar
        case (_, true): cursorStyle = .blinkBlock
        case (_, false): cursorStyle = .steadyBlock
        }

        let terminal = terminalView.getTerminal()
        terminal.setCursorStyle(cursorStyle)
        terminal.changeScrollback(settings.scrollbackLines)
        terminalView.optionAsMetaKey = settings.optionAsMetaKey
    }
}

public struct SwiftTermHostView: UIViewRepresentable {
    @ObservedObject var model: SwiftTermHostModel
    let theme: SwiftTermTheme
    let runtimeSettings: SwiftTermRuntimeSettings
    let onSendData: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onTitleChanged: (String) -> Void
    let onBell: () -> Void

    public init(
        model: SwiftTermHostModel,
        theme: SwiftTermTheme,
        runtimeSettings: SwiftTermRuntimeSettings,
        onSendData: @escaping (Data) -> Void,
        onResize: @escaping (Int, Int) -> Void,
        onTitleChanged: @escaping (String) -> Void = { _ in },
        onBell: @escaping () -> Void = {}
    ) {
        self.model = model
        self.theme = theme
        self.runtimeSettings = runtimeSettings
        self.onSendData = onSendData
        self.onResize = onResize
        self.onTitleChanged = onTitleChanged
        self.onBell = onBell
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            onSendData: onSendData,
            onResize: onResize,
            onTitleChanged: onTitleChanged,
            onBell: onBell
        )
    }

    public func makeUIView(context: Context) -> UIView {
        let engine = makeEngine(delegate: context.coordinator)
        engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        context.coordinator.engine = engine
        context.coordinator.lastTheme = theme
        context.coordinator.lastRuntimeSettings = runtimeSettings

        // Dismiss an active edit menu on any tap. The eye+hand input model can
        // otherwise leave it visible after the selection interaction ends.
        let dismissMenuTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.dismissEditMenu(_:))
        )
        dismissMenuTap.cancelsTouchesInView = false
        engine.hostView.addGestureRecognizer(dismissMenuTap)

        model.attach(engine)
        return engine.hostView
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if uiView.layer.cornerRadius != 18 {
            uiView.layer.cornerRadius = 18
        }
        if !uiView.layer.masksToBounds {
            uiView.layer.masksToBounds = true
        }
        guard let engine = context.coordinator.engine,
              engine.hostView === uiView else { return }
        var needsConfiguration = false
        if context.coordinator.lastTheme != theme {
            context.coordinator.lastTheme = theme
            needsConfiguration = true
        }
        if context.coordinator.lastRuntimeSettings != runtimeSettings {
            context.coordinator.lastRuntimeSettings = runtimeSettings
            needsConfiguration = true
        }
        if needsConfiguration {
            engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        }
        model.attach(engine)
    }

    private func makeEngine(delegate: TerminalViewDelegate) -> any TerminalEngine {
        SwiftTermEngine(
            delegate: delegate,
            onPasteRequest: { [weak model] text, bracketed in
                model?.requestPaste(text, bracketed: bracketed)
            },
            onPasteData: onSendData,
            onRendererDiagnostics: { [weak model] diagnostics in
                DispatchQueue.main.async { [weak model] in
                    model?.updateRendererDiagnostics(diagnostics)
                }
            },
            onOSC52Decision: { [weak model] decision in
                model?.recordOSC52Decision(decision)
            }
        )
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private weak var model: SwiftTermHostModel?
        private let onSendData: (Data) -> Void
        private let onResize: (Int, Int) -> Void
        private let onTitleChanged: (String) -> Void
        private let onBell: () -> Void
        fileprivate var engine: (any TerminalEngine)?
        fileprivate var lastTheme: SwiftTermTheme?
        fileprivate var lastRuntimeSettings: SwiftTermRuntimeSettings?

        init(
            model: SwiftTermHostModel,
            onSendData: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitleChanged: @escaping (String) -> Void,
            onBell: @escaping () -> Void
        ) {
            self.model = model
            self.onSendData = onSendData
            self.onResize = onResize
            self.onTitleChanged = onTitleChanged
            self.onBell = onBell
        }

        @objc @MainActor func dismissEditMenu(_ sender: UITapGestureRecognizer) {
            sender.view?.interactions
                .compactMap { $0 as? UIEditMenuInteraction }
                .forEach { $0.dismissMenu() }
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            onTitleChanged(title)
        }

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            Task { @MainActor [weak model] in
                model?.updateCurrentDirectory(directory)
            }
        }

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            engine?.recordInput(byteCount: data.count)
            onSendData(Data(data))
        }

        public func scrolled(source: TerminalView, position: Double) {
            engine?.refreshAccessibilityViewport()
            Task { @MainActor [weak model] in
                model?.updateScrollPosition(position)
            }
        }

        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            // Remote OSC data can request review, but only the app-owned host
            // UI may authorize navigation and call UIApplication.open.
            Task { @MainActor [weak model] in
                model?.requestExternalLink(link)
            }
        }
        public func bell(source: TerminalView) { onBell() }
        public func clipboardCopy(source: TerminalView, content: Data) {
            // Backstop only: the engine's OSC 52 override denies requests
            // before SwiftTerm decodes content or reaches this delegate.
        }
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            // Record bounded metadata only. Remote file payloads are never
            // retained or persisted by the semantic event stream.
            let kind = SwiftTermITermContentPolicy.semanticEventKind(for: content)
            Task { @MainActor [weak model] in
                model?.recordITermEvent(kind)
            }
        }
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            Task { @MainActor [weak model] in
                model?.recordDisplayRange(startY: startY, endY: endY)
            }
        }
    }
}
#elseif canImport(AppKit)
@MainActor
private protocol TerminalEngine: AnyObject {
    var identity: ObjectIdentifier { get }
    var hostView: NSView { get }
    var isLikelyRunningInteractiveProgram: Bool { get }
    var isComposingText: Bool { get }
    var rendererDiagnostics: SwiftTermRendererDiagnostics { get }
    var performanceDiagnostics: SwiftTermPerformanceDiagnostics { get }

    func configure(theme: SwiftTermTheme, runtimeSettings: SwiftTermRuntimeSettings)
    func receive(_ data: Data)
    func recordInput(byteCount: Int)
    func focusIfActive() -> Bool
    func resignFocus()
    func refreshAccessibilityViewport()
    func visibleText(lastNLines: Int) -> [String]
    func findNext(_ term: String) -> Bool
    func findPrevious(_ term: String) -> Bool
    func clearSearch()
    func commitPaste(_ text: String, bracketed: Bool)
}

@MainActor
private final class ReviewingMacTerminalView: TerminalView {
    var onPasteRequest: ((String, Bool) -> Void)?
    var onWindowAttachmentChanged: (() -> Void)?

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachmentChanged?()
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onPasteRequest?(text, getTerminal().bracketedPasteMode)
    }
}

@MainActor
private final class MacSwiftTermEngine: TerminalEngine {
    let terminalView: ReviewingMacTerminalView
    private let onPasteData: (Data) -> Void
    private let onRendererDiagnostics: (SwiftTermRendererDiagnostics) -> Void
    private let onOSC52Decision: (SwiftTermOSC52Decision) -> Void
    private let performanceClock = ContinuousClock()
    private(set) var rendererDiagnostics = SwiftTermRendererDiagnostics.awaitingWindow
    private(set) var performanceDiagnostics = SwiftTermPerformanceDiagnostics()

    init(
        delegate: TerminalViewDelegate,
        onPasteRequest: @escaping (String, Bool) -> Void,
        onPasteData: @escaping (Data) -> Void,
        onRendererDiagnostics: @escaping (SwiftTermRendererDiagnostics) -> Void,
        onOSC52Decision: @escaping (SwiftTermOSC52Decision) -> Void
    ) {
        terminalView = ReviewingMacTerminalView(frame: .zero)
        self.onPasteData = onPasteData
        self.onRendererDiagnostics = onRendererDiagnostics
        self.onOSC52Decision = onOSC52Decision
        terminalView.terminalDelegate = delegate
        terminalView.onPasteRequest = onPasteRequest
        terminalView.notifyUpdateChanges = true
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityLabel("Terminal")
        terminalView.setAccessibilityHelp("Interactive terminal input and output")
        terminalView.onWindowAttachmentChanged = { [weak self] in
            self?.publishRendererDiagnostics()
        }
        terminalView.getTerminal().parser.oscHandlers[52] = { [weak self] request in
            guard let self else { return }
            self.onOSC52Decision(SwiftTermOSC52Policy.evaluate(request))
        }
    }

    var identity: ObjectIdentifier { ObjectIdentifier(terminalView) }
    var hostView: NSView { terminalView }
    var isLikelyRunningInteractiveProgram: Bool {
        terminalView.getTerminal().isCurrentBufferAlternate
    }
    var isComposingText: Bool { terminalView.hasMarkedText() }

    func configure(theme: SwiftTermTheme, runtimeSettings: SwiftTermRuntimeSettings) {
        applyTheme(theme)
        applyRuntimeSettings(runtimeSettings)
        publishRendererDiagnostics()
    }

    func receive(_ data: Data) {
        let start = performanceClock.now
        terminalView.feed(byteArray: ArraySlice(data))
        performanceDiagnostics.recordFeed(
            byteCount: data.count,
            duration: start.duration(to: performanceClock.now)
        )
        refreshAccessibilityViewport()
    }

    func recordInput(byteCount: Int) {
        performanceDiagnostics.recordInput(byteCount: byteCount)
    }

    func focusIfActive() -> Bool {
        guard let window = terminalView.window, window.isKeyWindow else { return false }
        if window.firstResponder === terminalView { return true }
        guard !isComposingText else { return false }
        return window.makeFirstResponder(terminalView)
    }

    func resignFocus() {
        guard let window = terminalView.window, window.firstResponder === terminalView else { return }
        window.makeFirstResponder(nil)
    }

    func refreshAccessibilityViewport() {
        let value = visibleText(lastNLines: 40).joined(separator: "\n")
        terminalView.setAccessibilityValue(value.isEmpty ? "No visible output" : value)
    }

    func visibleText(lastNLines: Int) -> [String] {
        let data = terminalView.getTerminal().getBufferAsData()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(lines.suffix(max(0, lastNLines)))
    }

    func findNext(_ term: String) -> Bool { terminalView.findNext(term) }
    func findPrevious(_ term: String) -> Bool { terminalView.findPrevious(term) }
    func clearSearch() { terminalView.clearSearch() }

    func commitPaste(_ text: String, bracketed: Bool) {
        let data = SwiftTermPastePolicy.framedData(for: text, bracketed: bracketed)
        recordInput(byteCount: data.count)
        onPasteData(data)
    }

    private func applyTheme(_ theme: SwiftTermTheme) {
        let fontSize = max(10, theme.fontSize)
        terminalView.font = theme.fontName == "SF Mono"
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont(name: theme.fontName, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(
            srgbRed: theme.foreground.red,
            green: theme.foreground.green,
            blue: theme.foreground.blue,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = NSColor(
            srgbRed: theme.background.red,
            green: theme.background.green,
            blue: theme.background.blue,
            alpha: theme.background.alpha
        )
        terminalView.caretColor = NSColor(
            srgbRed: theme.cursor.red,
            green: theme.cursor.green,
            blue: theme.cursor.blue,
            alpha: 1
        )
        terminalView.selectedTextBackgroundColor = NSColor(
            srgbRed: theme.selection.red,
            green: theme.selection.green,
            blue: theme.selection.blue,
            alpha: theme.selection.alpha
        )
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        if theme.ansiColors.count == 16 {
            terminalView.installColors(theme.ansiColors.map { color in
                SwiftTerm.Color(
                    red: Self.terminalColorComponent(color.red),
                    green: Self.terminalColorComponent(color.green),
                    blue: Self.terminalColorComponent(color.blue)
                )
            })
        }
    }

    private func applyRuntimeSettings(_ settings: SwiftTermRuntimeSettings) {
        let normalizedStyle = settings.cursorStyle.lowercased()
        let cursorStyle: CursorStyle
        switch (normalizedStyle, settings.blinkingCursor) {
        case ("underline", true): cursorStyle = .blinkUnderline
        case ("underline", false): cursorStyle = .steadyUnderline
        case ("bar", true): cursorStyle = .blinkBar
        case ("bar", false): cursorStyle = .steadyBar
        case (_, true): cursorStyle = .blinkBlock
        case (_, false): cursorStyle = .steadyBlock
        }
        terminalView.getTerminal().setCursorStyle(cursorStyle)
        terminalView.changeScrollback(settings.scrollbackLines)
        terminalView.optionAsMetaKey = settings.optionAsMetaKey
    }

    private func publishRendererDiagnostics() {
        let diagnostics = SwiftTermRendererDiagnostics(
            backend: .coreGraphicsFallback,
            isWindowAttached: terminalView.window != nil,
            hostBackingIsClear: terminalView.layer?.backgroundColor?.alpha == 0,
            rendererBackingIsClear: true,
            failureDescription: nil
        )
        rendererDiagnostics = diagnostics
        onRendererDiagnostics(diagnostics)
    }

    private static func terminalColorComponent(_ component: Double) -> UInt16 {
        UInt16((min(1, max(0, component)) * Double(UInt16.max)).rounded())
    }
}

public struct SwiftTermHostView: NSViewRepresentable {
    @ObservedObject var model: SwiftTermHostModel
    let theme: SwiftTermTheme
    let runtimeSettings: SwiftTermRuntimeSettings
    let onSendData: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onTitleChanged: (String) -> Void
    let onBell: () -> Void

    public init(
        model: SwiftTermHostModel,
        theme: SwiftTermTheme,
        runtimeSettings: SwiftTermRuntimeSettings,
        onSendData: @escaping (Data) -> Void,
        onResize: @escaping (Int, Int) -> Void,
        onTitleChanged: @escaping (String) -> Void = { _ in },
        onBell: @escaping () -> Void = {}
    ) {
        self.model = model
        self.theme = theme
        self.runtimeSettings = runtimeSettings
        self.onSendData = onSendData
        self.onResize = onResize
        self.onTitleChanged = onTitleChanged
        self.onBell = onBell
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            onSendData: onSendData,
            onResize: onResize,
            onTitleChanged: onTitleChanged,
            onBell: onBell
        )
    }

    public func makeNSView(context: Context) -> NSView {
        let engine = MacSwiftTermEngine(
            delegate: context.coordinator,
            onPasteRequest: { [weak model] text, bracketed in
                model?.requestPaste(text, bracketed: bracketed)
            },
            onPasteData: onSendData,
            onRendererDiagnostics: { [weak model] diagnostics in
                model?.updateRendererDiagnostics(diagnostics)
            },
            onOSC52Decision: { [weak model] decision in
                model?.recordOSC52Decision(decision)
            }
        )
        engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        context.coordinator.engine = engine
        context.coordinator.lastTheme = theme
        context.coordinator.lastRuntimeSettings = runtimeSettings
        model.attach(engine)
        return engine.hostView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let engine = context.coordinator.engine, engine.hostView === nsView else { return }
        if context.coordinator.lastTheme != theme
            || context.coordinator.lastRuntimeSettings != runtimeSettings {
            context.coordinator.lastTheme = theme
            context.coordinator.lastRuntimeSettings = runtimeSettings
            engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        }
        model.attach(engine)
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private weak var model: SwiftTermHostModel?
        private let onSendData: (Data) -> Void
        private let onResize: (Int, Int) -> Void
        private let onTitleChanged: (String) -> Void
        private let onBell: () -> Void
        fileprivate var engine: (any TerminalEngine)?
        fileprivate var lastTheme: SwiftTermTheme?
        fileprivate var lastRuntimeSettings: SwiftTermRuntimeSettings?

        init(
            model: SwiftTermHostModel,
            onSendData: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            onTitleChanged: @escaping (String) -> Void,
            onBell: @escaping () -> Void
        ) {
            self.model = model
            self.onSendData = onSendData
            self.onResize = onResize
            self.onTitleChanged = onTitleChanged
            self.onBell = onBell
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        public func setTerminalTitle(source: TerminalView, title: String) {
            onTitleChanged(title)
        }

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            model?.updateCurrentDirectory(directory)
        }

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            engine?.recordInput(byteCount: data.count)
            onSendData(Data(data))
        }

        public func scrolled(source: TerminalView, position: Double) {
            engine?.refreshAccessibilityViewport()
            model?.updateScrollPosition(position)
        }

        public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            model?.requestExternalLink(link)
        }

        public func bell(source: TerminalView) { onBell() }
        public func clipboardCopy(source: TerminalView, content: Data) {
            // Backstop only: the engine's OSC 52 override denies requests
            // before SwiftTerm decodes content or reaches this delegate.
        }

        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
            model?.recordITermEvent(SwiftTermITermContentPolicy.semanticEventKind(for: content))
        }

        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            model?.recordDisplayRange(startY: startY, endY: endY)
        }
    }
}

/// A local-process launch description that always passes the executable and
/// arguments to `exec` separately. No shell command string is constructed.
public struct SwiftTermLocalProcessConfiguration: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]?
    public var executableName: String?
    public var currentDirectory: String?

    public init(
        executable: String = "/bin/zsh",
        arguments: [String] = ["-l"],
        environment: [String]? = nil,
        executableName: String? = nil,
        currentDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.executableName = executableName
        self.currentDirectory = currentDirectory
    }

    fileprivate var validationFailure: String? {
        guard !executable.isEmpty, executable.hasPrefix("/") else {
            return "The local terminal executable must be an absolute path."
        }
        guard !Self.containsNullByte(executable),
              !arguments.contains(where: Self.containsNullByte),
              executableName.map({ !$0.isEmpty && !Self.containsNullByte($0) }) ?? true,
              currentDirectory.map({ $0.hasPrefix("/") && !Self.containsNullByte($0) }) ?? true else {
            return "The local terminal launch configuration contains an invalid path or argument."
        }
        if let environmentFailure = Self.environmentValidationFailure(environment) {
            return environmentFailure
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "The local terminal executable does not exist or is not executable."
        }
        if let currentDirectory {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: currentDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "The local terminal working directory does not exist or is not a directory."
            }
        }
        return nil
    }

    private static func containsNullByte(_ value: String) -> Bool {
        value.utf8.contains(0)
    }

    private static func environmentValidationFailure(_ environment: [String]?) -> String? {
        guard let environment else { return nil }
        var names = Set<Substring>()
        for entry in environment {
            guard !containsNullByte(entry),
                  let separator = entry.firstIndex(of: "="),
                  separator != entry.startIndex else {
                return "Each local terminal environment entry must use a non-empty NAME=value form."
            }
            let name = entry[..<separator]
            guard names.insert(name).inserted else {
                return "The local terminal environment contains a duplicate variable named \(name)."
            }
        }
        return nil
    }
}

@MainActor
private protocol SwiftTermLocalProcessControlling: AnyObject {
    func focusLocalProcess()
    func terminateLocalProcess()
    @discardableResult
    func restartLocalProcess(_ configuration: SwiftTermLocalProcessConfiguration) -> Bool
    @discardableResult
    func sendLocalCommand(_ command: String) -> Bool
    func clearLocalDisplay()
    func toggleLocalProcessFullScreen()
}

/// Observable lifecycle state for a local SwiftTerm process. The controller is
/// weak so retaining this model never keeps a window or shell process alive.
@MainActor
public final class SwiftTermLocalProcessState: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var terminalTitle: String?
    @Published public private(set) var currentDirectory: String?
    @Published public private(set) var exitCode: Int32?
    @Published public private(set) var launchError: String?

    private weak var controller: (any SwiftTermLocalProcessControlling)?

    public init() {}

    public func focus() {
        controller?.focusLocalProcess()
    }

    public func terminate() {
        controller?.terminateLocalProcess()
    }

    /// Relaunches the configured local process in the existing terminal after
    /// the prior child has exited. A running process is never replaced.
    @discardableResult
    public func restart(_ configuration: SwiftTermLocalProcessConfiguration) -> Bool {
        controller?.restartLocalProcess(configuration) ?? false
    }

    /// Sends the exact command bytes followed by a carriage return to the
    /// existing PTY. This never invokes a second shell or constructs a
    /// `shell -c` command line; the running interactive process receives the
    /// same input it would receive from the keyboard.
    @discardableResult
    public func sendCommand(_ command: String) -> Bool {
        controller?.sendLocalCommand(command) ?? false
    }

    /// Clears only the local terminal emulator's display and scrollback. The
    /// shell process, working directory, environment, and PTY remain intact.
    public func clearDisplay() {
        controller?.clearLocalDisplay()
    }

    /// Toggles full screen on the NSWindow that owns this PTY, avoiding global
    /// key-window routing when several terminal windows are open.
    public func toggleFullScreen() {
        controller?.toggleLocalProcessFullScreen()
    }

    fileprivate func attach(_ controller: any SwiftTermLocalProcessControlling) {
        self.controller = controller
    }

    fileprivate func beganRunning(currentDirectory: String?) {
        isRunning = true
        exitCode = nil
        launchError = nil
        terminalTitle = nil
        self.currentDirectory = currentDirectory
    }

    fileprivate func failedToLaunch(_ message: String) {
        isRunning = false
        exitCode = nil
        launchError = message
    }

    fileprivate func processTerminated(exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode
    }

    fileprivate func updateTitle(_ title: String) {
        terminalTitle = title
    }

    fileprivate func updateCurrentDirectory(_ directory: String?) {
        currentDirectory = directory
    }
}

@MainActor
private final class ReviewingMacLocalProcessTerminalView: LocalProcessTerminalView {
    var onPasteRequest: ((String, Bool) -> Void)?
    var onWindowAttachmentChanged: (() -> Void)?
    var onProcessOutput: ((ArraySlice<UInt8>, Duration) -> Void)?

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachmentChanged?()
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onPasteRequest?(text, getTerminal().bracketedPasteMode)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let clock = ContinuousClock()
        let start = clock.now
        super.dataReceived(slice: slice)
        onProcessOutput?(slice, start.duration(to: clock.now))
    }
}

@MainActor
private final class MacLocalProcessDelegateProxy:
    NSObject,
    @preconcurrency TerminalViewDelegate,
    @preconcurrency LocalProcessTerminalViewDelegate
{
    weak var terminalView: ReviewingMacLocalProcessTerminalView?
    weak var engine: MacLocalProcessEngine?
    weak var hostModel: SwiftTermHostModel?
    weak var processState: SwiftTermLocalProcessState?

    let onResize: (Int, Int) -> Void
    let onTitleChanged: (String) -> Void
    let onCurrentDirectoryChanged: (String?) -> Void
    let onBell: () -> Void
    let onProcessTerminated: (Int32?) -> Void

    init(
        hostModel: SwiftTermHostModel,
        processState: SwiftTermLocalProcessState,
        onResize: @escaping (Int, Int) -> Void,
        onTitleChanged: @escaping (String) -> Void,
        onCurrentDirectoryChanged: @escaping (String?) -> Void,
        onBell: @escaping () -> Void,
        onProcessTerminated: @escaping (Int32?) -> Void
    ) {
        self.hostModel = hostModel
        self.processState = processState
        self.onResize = onResize
        self.onTitleChanged = onTitleChanged
        self.onCurrentDirectoryChanged = onCurrentDirectoryChanged
        self.onBell = onBell
        self.onProcessTerminated = onProcessTerminated
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Preserve LocalProcessTerminalView's ioctl-backed resize behavior after
        // replacing its delegate with this policy proxy.
        terminalView?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processState?.updateTitle(title)
        onTitleChanged(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        hostModel?.updateCurrentDirectory(directory)
        processState?.updateCurrentDirectory(directory)
        onCurrentDirectoryChanged(directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        engine?.sendUserInput(data)
    }

    func scrolled(source: TerminalView, position: Double) {
        engine?.refreshAccessibilityViewport()
        hostModel?.updateScrollPosition(position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Never inherit SwiftTerm's macOS default, which opens NSWorkspace
        // immediately. The shared host model requires explicit user review.
        hostModel?.requestExternalLink(link)
    }

    func bell(source: TerminalView) {
        onBell()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // Backstop only. OSC 52 is replaced at the parser before SwiftTerm can
        // decode or deliver clipboard content here.
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        hostModel?.recordITermEvent(SwiftTermITermContentPolicy.semanticEventKind(for: content))
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        hostModel?.recordDisplayRange(startY: startY, endY: endY)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        onResize(newCols, newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        processState?.updateTitle(title)
        onTitleChanged(title)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let engine {
            engine.processDidTerminate(waitStatus: exitCode)
        } else {
            let normalizedExitCode = Self.normalizedForkPTYExitCode(exitCode)
            processState?.processTerminated(exitCode: normalizedExitCode)
            onProcessTerminated(normalizedExitCode)
        }
    }

    fileprivate static func normalizedForkPTYExitCode(_ waitStatus: Int32?) -> Int32? {
        guard let waitStatus else { return nil }
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if terminatingSignal == 0x7f {
            return nil
        }
        return 128 + terminatingSignal
    }
}

@MainActor
private final class MacLocalProcessEngine: TerminalEngine, SwiftTermLocalProcessControlling {
    static let maximumRecordingCallbackBytes = 64 * 1024

    let terminalView: ReviewingMacLocalProcessTerminalView
    private let delegateProxy: MacLocalProcessDelegateProxy
    private weak var processState: SwiftTermLocalProcessState?
    private let onOutputData: (Data) -> Void
    private let onInputData: (Data) -> Void
    private let onProcessTerminated: (Int32?) -> Void
    private let onRendererDiagnostics: (SwiftTermRendererDiagnostics) -> Void
    private let onOSC52Decision: (SwiftTermOSC52Decision) -> Void
    private var didReportTermination = false
    private(set) var rendererDiagnostics = SwiftTermRendererDiagnostics.awaitingWindow
    private(set) var performanceDiagnostics = SwiftTermPerformanceDiagnostics()

    init(
        hostModel: SwiftTermHostModel,
        processState: SwiftTermLocalProcessState,
        onPasteRequest: @escaping (String, Bool) -> Void,
        onOutputData: @escaping (Data) -> Void,
        onInputData: @escaping (Data) -> Void,
        onResize: @escaping (Int, Int) -> Void,
        onTitleChanged: @escaping (String) -> Void,
        onCurrentDirectoryChanged: @escaping (String?) -> Void,
        onBell: @escaping () -> Void,
        onProcessTerminated: @escaping (Int32?) -> Void,
        onRendererDiagnostics: @escaping (SwiftTermRendererDiagnostics) -> Void,
        onOSC52Decision: @escaping (SwiftTermOSC52Decision) -> Void
    ) {
        let terminalView = ReviewingMacLocalProcessTerminalView(frame: .zero)
        let delegateProxy = MacLocalProcessDelegateProxy(
            hostModel: hostModel,
            processState: processState,
            onResize: onResize,
            onTitleChanged: onTitleChanged,
            onCurrentDirectoryChanged: onCurrentDirectoryChanged,
            onBell: onBell,
            onProcessTerminated: onProcessTerminated
        )
        self.terminalView = terminalView
        self.delegateProxy = delegateProxy
        self.processState = processState
        self.onOutputData = onOutputData
        self.onInputData = onInputData
        self.onProcessTerminated = onProcessTerminated
        self.onRendererDiagnostics = onRendererDiagnostics
        self.onOSC52Decision = onOSC52Decision

        delegateProxy.terminalView = terminalView
        delegateProxy.engine = self
        terminalView.terminalDelegate = delegateProxy
        terminalView.processDelegate = delegateProxy
        terminalView.onPasteRequest = onPasteRequest
        terminalView.onProcessOutput = { [weak self] bytes, duration in
            self?.recordProcessOutput(bytes, duration: duration)
        }
        terminalView.onWindowAttachmentChanged = { [weak self] in
            self?.publishRendererDiagnostics()
        }
        terminalView.notifyUpdateChanges = true
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityLabel("Local terminal")
        terminalView.setAccessibilityHelp("Interactive local process terminal input and output")

        terminalView.getTerminal().parser.oscHandlers[52] = { [weak self] request in
            guard let self else { return }
            self.onOSC52Decision(SwiftTermOSC52Policy.evaluate(request))
        }
    }

    var identity: ObjectIdentifier { ObjectIdentifier(terminalView) }
    var hostView: NSView { terminalView }
    var isLikelyRunningInteractiveProgram: Bool {
        terminalView.getTerminal().isCurrentBufferAlternate
    }
    var isComposingText: Bool { terminalView.hasMarkedText() }

    func configure(theme: SwiftTermTheme, runtimeSettings: SwiftTermRuntimeSettings) {
        applyTheme(theme)
        applyRuntimeSettings(runtimeSettings)
        publishRendererDiagnostics()
        updatePTYSize()
    }

    func start(_ configuration: SwiftTermLocalProcessConfiguration) {
        guard let processState else { return }
        if let failure = configuration.validationFailure {
            processState.failedToLaunch(failure)
            return
        }
        guard !terminalView.process.running else { return }

        didReportTermination = false
        terminalView.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: configuration.environment,
            execName: configuration.executableName,
            currentDirectory: configuration.currentDirectory
        )
        guard terminalView.process.running else {
            processState.failedToLaunch("The local terminal process could not be started.")
            return
        }
        processState.beganRunning(currentDirectory: configuration.currentDirectory)
        if let currentDirectory = configuration.currentDirectory {
            delegateProxy.hostCurrentDirectoryUpdate(
                source: terminalView,
                directory: currentDirectory
            )
        }
        updatePTYSize()
    }

    func receive(_ data: Data) {
        let clock = ContinuousClock()
        let start = clock.now
        terminalView.feed(byteArray: ArraySlice(data))
        performanceDiagnostics.recordFeed(
            byteCount: data.count,
            duration: start.duration(to: clock.now)
        )
        refreshAccessibilityViewport()
    }

    func recordInput(byteCount: Int) {
        performanceDiagnostics.recordInput(byteCount: byteCount)
    }

    func sendUserInput(_ bytes: ArraySlice<UInt8>) {
        guard terminalView.process.running, !bytes.isEmpty else { return }
        recordInput(byteCount: bytes.count)
        emitBounded(Data(bytes), to: onInputData)
        terminalView.send(source: terminalView, data: bytes)
    }

    func focusIfActive() -> Bool {
        guard let window = terminalView.window, window.isKeyWindow else { return false }
        if window.firstResponder === terminalView { return true }
        guard !isComposingText else { return false }
        return window.makeFirstResponder(terminalView)
    }

    func focusLocalProcess() {
        _ = focusIfActive()
    }

    @discardableResult
    func sendLocalCommand(_ command: String) -> Bool {
        guard terminalView.process.running,
              !command.isEmpty,
              !command.utf8.contains(0),
              command.utf8.count <= SwiftTermPastePolicy.maximumPayloadBytes else {
            return false
        }
        var input = Data(command.utf8)
        input.append(0x0d)
        sendUserInput(ArraySlice(input))
        return true
    }

    func clearLocalDisplay() {
        terminalView.getTerminal().resetToInitialState()
        terminalView.needsDisplay = true
        refreshAccessibilityViewport()
    }

    func toggleLocalProcessFullScreen() {
        terminalView.window?.toggleFullScreen(nil)
    }

    func resignFocus() {
        guard let window = terminalView.window, window.firstResponder === terminalView else { return }
        window.makeFirstResponder(nil)
    }

    func terminateLocalProcess() {
        let processID = terminalView.process.shellPid
        guard processID > 0 else {
            reportProcessTermination(exitCode: nil)
            return
        }

        var waitStatus: Int32 = 0
        let waitResult = Self.nonblockingWait(processID, status: &waitStatus)
        if waitResult == processID {
            // PTY EOF can arrive before SwiftTerm's process source. Reap here
            // before the view disappears, without signalling a now-reusable PID.
            reportProcessTermination(
                exitCode: MacLocalProcessDelegateProxy.normalizedForkPTYExitCode(waitStatus)
            )
            return
        }
        if waitResult == -1, errno == ECHILD {
            // SwiftTerm's process source already won the waitpid race.
            reportProcessTermination(exitCode: nil)
            return
        }

        // SwiftTerm closes the PTY and sends SIGTERM, but also cancels its only
        // waitpid source. A dedicated reaper therefore owns this child from this
        // point forward and escalates only if the direct shell ignores SIGTERM.
        terminalView.terminate()
        reportProcessTermination(exitCode: nil)
        Self.reapTerminatedProcess(processID)
    }

    @discardableResult
    func restartLocalProcess(_ configuration: SwiftTermLocalProcessConfiguration) -> Bool {
        guard !terminalView.process.running else { return false }
        terminalView.getTerminal().resetToInitialState()
        terminalView.needsDisplay = true
        start(configuration)
        return terminalView.process.running
    }

    fileprivate func processDidTerminate(waitStatus: Int32?) {
        reportProcessTermination(
            exitCode: MacLocalProcessDelegateProxy.normalizedForkPTYExitCode(waitStatus)
        )
    }

    private func reportProcessTermination(exitCode: Int32?) {
        guard !didReportTermination else { return }
        didReportTermination = true
        processState?.processTerminated(exitCode: exitCode)
        onProcessTerminated(exitCode)
    }

    nonisolated private static func nonblockingWait(
        _ processID: pid_t,
        status: inout Int32
    ) -> pid_t {
        while true {
            let result = waitpid(processID, &status, WNOHANG)
            if result == -1, errno == EINTR { continue }
            return result
        }
    }

    nonisolated private static func reapTerminatedProcess(_ processID: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            let deadline = DispatchTime.now() + .seconds(2)
            var status: Int32 = 0
            while DispatchTime.now() < deadline {
                let result = nonblockingWait(processID, status: &status)
                if result == processID || (result == -1 && errno == ECHILD) {
                    return
                }
                if result == -1 { return }
                usleep(20_000)
            }

            if kill(processID, SIGKILL) == -1, errno == ESRCH { return }
            while waitpid(processID, &status, 0) == -1 {
                if errno == EINTR { continue }
                return
            }
        }
    }

    func refreshAccessibilityViewport() {
        let value = visibleText(lastNLines: 40).joined(separator: "\n")
        terminalView.setAccessibilityValue(value.isEmpty ? "No visible output" : value)
    }

    func visibleText(lastNLines: Int) -> [String] {
        let data = terminalView.getTerminal().getBufferAsData()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(lines.suffix(max(0, lastNLines)))
    }

    func findNext(_ term: String) -> Bool { terminalView.findNext(term) }
    func findPrevious(_ term: String) -> Bool { terminalView.findPrevious(term) }
    func clearSearch() { terminalView.clearSearch() }

    func commitPaste(_ text: String, bracketed: Bool) {
        let data = SwiftTermPastePolicy.framedData(for: text, bracketed: bracketed)
        sendUserInput(ArraySlice(data))
    }

    private func recordProcessOutput(_ bytes: ArraySlice<UInt8>, duration: Duration) {
        performanceDiagnostics.recordFeed(byteCount: bytes.count, duration: duration)
        emitBounded(Data(bytes), to: onOutputData)
        refreshAccessibilityViewport()
    }

    private func updatePTYSize() {
        guard terminalView.process.running else { return }
        let terminal = terminalView.getTerminal()
        terminalView.sizeChanged(
            source: terminalView,
            newCols: terminal.cols,
            newRows: terminal.rows
        )
    }

    private func applyTheme(_ theme: SwiftTermTheme) {
        let fontSize = max(10, theme.fontSize)
        terminalView.font = theme.fontName == "SF Mono"
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont(name: theme.fontName, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(
            srgbRed: theme.foreground.red,
            green: theme.foreground.green,
            blue: theme.foreground.blue,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = NSColor(
            srgbRed: theme.background.red,
            green: theme.background.green,
            blue: theme.background.blue,
            alpha: theme.background.alpha
        )
        terminalView.caretColor = NSColor(
            srgbRed: theme.cursor.red,
            green: theme.cursor.green,
            blue: theme.cursor.blue,
            alpha: 1
        )
        terminalView.selectedTextBackgroundColor = NSColor(
            srgbRed: theme.selection.red,
            green: theme.selection.green,
            blue: theme.selection.blue,
            alpha: theme.selection.alpha
        )
        terminalView.layer?.backgroundColor = NSColor.clear.cgColor
        if theme.ansiColors.count == 16 {
            terminalView.installColors(theme.ansiColors.map { color in
                SwiftTerm.Color(
                    red: Self.terminalColorComponent(color.red),
                    green: Self.terminalColorComponent(color.green),
                    blue: Self.terminalColorComponent(color.blue)
                )
            })
        }
    }

    private func applyRuntimeSettings(_ settings: SwiftTermRuntimeSettings) {
        let normalizedStyle = settings.cursorStyle.lowercased()
        let cursorStyle: CursorStyle
        switch (normalizedStyle, settings.blinkingCursor) {
        case ("underline", true): cursorStyle = .blinkUnderline
        case ("underline", false): cursorStyle = .steadyUnderline
        case ("bar", true): cursorStyle = .blinkBar
        case ("bar", false): cursorStyle = .steadyBar
        case (_, true): cursorStyle = .blinkBlock
        case (_, false): cursorStyle = .steadyBlock
        }
        terminalView.getTerminal().setCursorStyle(cursorStyle)
        terminalView.changeScrollback(settings.scrollbackLines)
        terminalView.optionAsMetaKey = settings.optionAsMetaKey
    }

    private func publishRendererDiagnostics() {
        let diagnostics = SwiftTermRendererDiagnostics(
            backend: .coreGraphicsFallback,
            isWindowAttached: terminalView.window != nil,
            hostBackingIsClear: terminalView.layer?.backgroundColor?.alpha == 0,
            rendererBackingIsClear: true,
            failureDescription: nil
        )
        rendererDiagnostics = diagnostics
        onRendererDiagnostics(diagnostics)
    }

    private func emitBounded(_ data: Data, to callback: (Data) -> Void) {
        guard !data.isEmpty else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset,
                offsetBy: min(Self.maximumRecordingCallbackBytes, data.distance(from: offset, to: data.endIndex))
            )
            callback(Data(data[offset..<end]))
            offset = end
        }
    }

    private static func terminalColorComponent(_ component: Double) -> UInt16 {
        UInt16((min(1, max(0, component)) * Double(UInt16.max)).rounded())
    }
}

/// An AppKit SwiftTerm host backed by a real local pseudo-terminal. The local
/// process is started once when the representable is created and is terminated
/// when the view is dismantled. Output and input callbacks are delivered in
/// chunks no larger than 64 KiB so recording clients cannot receive unbounded
/// transient payloads.
public struct SwiftTermLocalProcessHostView: NSViewRepresentable {
    @ObservedObject var model: SwiftTermHostModel
    @ObservedObject var processState: SwiftTermLocalProcessState
    let configuration: SwiftTermLocalProcessConfiguration
    let theme: SwiftTermTheme
    let runtimeSettings: SwiftTermRuntimeSettings
    let onOutputData: (Data) -> Void
    let onInputData: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onTitleChanged: (String) -> Void
    let onCurrentDirectoryChanged: (String?) -> Void
    let onBell: () -> Void
    let onProcessTerminated: (Int32?) -> Void

    public init(
        model: SwiftTermHostModel,
        processState: SwiftTermLocalProcessState,
        configuration: SwiftTermLocalProcessConfiguration = .init(),
        theme: SwiftTermTheme,
        runtimeSettings: SwiftTermRuntimeSettings,
        onOutputData: @escaping (Data) -> Void = { _ in },
        onInputData: @escaping (Data) -> Void = { _ in },
        onResize: @escaping (Int, Int) -> Void = { _, _ in },
        onTitleChanged: @escaping (String) -> Void = { _ in },
        onCurrentDirectoryChanged: @escaping (String?) -> Void = { _ in },
        onBell: @escaping () -> Void = {},
        onProcessTerminated: @escaping (Int32?) -> Void = { _ in }
    ) {
        self.model = model
        self.processState = processState
        self.configuration = configuration
        self.theme = theme
        self.runtimeSettings = runtimeSettings
        self.onOutputData = onOutputData
        self.onInputData = onInputData
        self.onResize = onResize
        self.onTitleChanged = onTitleChanged
        self.onCurrentDirectoryChanged = onCurrentDirectoryChanged
        self.onBell = onBell
        self.onProcessTerminated = onProcessTerminated
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSView {
        let engine = MacLocalProcessEngine(
            hostModel: model,
            processState: processState,
            onPasteRequest: { [weak model] text, bracketed in
                model?.requestPaste(text, bracketed: bracketed)
            },
            onOutputData: onOutputData,
            onInputData: onInputData,
            onResize: onResize,
            onTitleChanged: onTitleChanged,
            onCurrentDirectoryChanged: onCurrentDirectoryChanged,
            onBell: onBell,
            onProcessTerminated: onProcessTerminated,
            onRendererDiagnostics: { [weak model] diagnostics in
                model?.updateRendererDiagnostics(diagnostics)
            },
            onOSC52Decision: { [weak model] decision in
                model?.recordOSC52Decision(decision)
            }
        )
        engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        context.coordinator.engine = engine
        context.coordinator.lastTheme = theme
        context.coordinator.lastRuntimeSettings = runtimeSettings
        model.attach(engine)
        processState.attach(engine)
        engine.start(configuration)
        return engine.hostView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let engine = context.coordinator.engine, engine.hostView === nsView else { return }
        if context.coordinator.lastTheme != theme
            || context.coordinator.lastRuntimeSettings != runtimeSettings {
            context.coordinator.lastTheme = theme
            context.coordinator.lastRuntimeSettings = runtimeSettings
            engine.configure(theme: theme, runtimeSettings: runtimeSettings)
        }
        model.attach(engine)
        processState.attach(engine)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.engine?.terminateLocalProcess()
    }

    @MainActor
    public final class Coordinator {
        fileprivate var engine: MacLocalProcessEngine?
        fileprivate var lastTheme: SwiftTermTheme?
        fileprivate var lastRuntimeSettings: SwiftTermRuntimeSettings?
    }
}
#endif
