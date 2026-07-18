import SwiftUI
#if canImport(UIKit)
import UIKit
import Combine
import SwiftTerm
#if canImport(MetalKit)
import MetalKit
#endif

public enum SwiftTermRendererBackend: String, Equatable, Sendable {
    case awaitingWindow
    case metal
    case coreGraphicsFallback
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
    /// SwiftTerm 1.13 maps legacy F10 to F9 and drops legacy F12-F24. Keep
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

    /// Sends only legacy function keys SwiftTerm 1.13 does not encode
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
            self?.activateMetalRendererIfAttached()
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
        activateMetalRendererIfAttached()
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

    private func activateMetalRendererIfAttached() {
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
#endif
