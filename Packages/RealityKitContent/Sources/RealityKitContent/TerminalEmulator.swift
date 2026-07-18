import Foundation
import SwiftTerm

private final class CapturingTerminalDelegate: TerminalDelegate {
    static let maximumCapturedOutboundBytes = 1_048_576

    private(set) var outboundData = Data()
    private(set) var outboundDataWasTruncated = false
    private(set) var synchronizedOutputActive = false

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        let remainingCapacity = Self.maximumCapturedOutboundBytes - outboundData.count
        guard remainingCapacity > 0 else {
            outboundDataWasTruncated = true
            return
        }
        if data.count > remainingCapacity {
            outboundData.append(contentsOf: data.prefix(remainingCapacity))
            outboundDataWasTruncated = true
        } else {
            outboundData.append(contentsOf: data)
        }
    }

    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        synchronizedOutputActive = active
    }

    func drainOutboundData() -> Data {
        defer {
            outboundData.removeAll(keepingCapacity: true)
            outboundDataWasTruncated = false
        }
        return outboundData
    }
}

public enum TerminalMouseReportingMode: String, Equatable, Sendable {
    case off
    case x10
    case vt200
    case buttonEventTracking
    case anyEvent
}

public struct TerminalRGBColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct TerminalCellStyle: Equatable, Sendable {
    public var foreground: TerminalRGBColor
    public var background: TerminalRGBColor?
    public var isBold: Bool
    public var isUnderlined: Bool
    public var isBlinking: Bool
    public var isInverse: Bool
    public var isInvisible: Bool
    public var isDim: Bool
    public var isItalic: Bool
    public var isCrossedOut: Bool
    public var underlineStyleRawValue: UInt8

    public init(
        foreground: TerminalRGBColor,
        background: TerminalRGBColor?,
        isBold: Bool = false,
        isUnderlined: Bool = false,
        isBlinking: Bool = false,
        isInverse: Bool = false,
        isInvisible: Bool = false,
        isDim: Bool = false,
        isItalic: Bool = false,
        isCrossedOut: Bool = false,
        underlineStyleRawValue: UInt8 = 0
    ) {
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isUnderlined = isUnderlined
        self.isBlinking = isBlinking
        self.isInverse = isInverse
        self.isInvisible = isInvisible
        self.isDim = isDim
        self.isItalic = isItalic
        self.isCrossedOut = isCrossedOut
        self.underlineStyleRawValue = underlineStyleRawValue
    }
}

public struct TerminalStyledCell: Equatable, Sendable {
    public var scalar: String
    public var columnWidth: Int
    public var style: TerminalCellStyle

    public init(scalar: String, columnWidth: Int = 1, style: TerminalCellStyle) {
        self.scalar = scalar
        self.columnWidth = columnWidth
        self.style = style
    }
}

@MainActor
public final class TerminalEmulator {
    private let terminalDelegate: CapturingTerminalDelegate
    private let terminal: Terminal
    public private(set) var rows: [String] = []
    public private(set) var styledRows: [[TerminalStyledCell]] = []
    public private(set) var cursor: (row: Int, col: Int) = (0, 0)
    public private(set) var columns: Int
    public private(set) var rowCount: Int
    public private(set) var isAlternateBufferActive = false
    public private(set) var isApplicationCursorModeActive = false
    public private(set) var isBracketedPasteModeActive = false
    public private(set) var mouseReportingMode: TerminalMouseReportingMode = .off
    public private(set) var kittyKeyboardFlagsRawValue = 0
    public var isSynchronizedOutputActive: Bool {
        terminalDelegate.synchronizedOutputActive
    }
    public var outboundDataWasTruncated: Bool {
        terminalDelegate.outboundDataWasTruncated
    }
    public var bufferLineCount: Int {
        terminal.getBufferAsData().reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "\n") { count += 1 }
        }
    }
    public var scrollbackLineCount: Int {
        max(0, bufferLineCount - rowCount)
    }

    public init(cols: Int = 120, rows: Int = 40) {
        let terminalDelegate = CapturingTerminalDelegate()
        self.terminalDelegate = terminalDelegate
        terminal = Terminal(delegate: terminalDelegate, options: TerminalOptions())
        columns = cols
        rowCount = rows
        terminal.resize(cols: cols, rows: rows)
        refreshSnapshot()
    }

    public func feed(data: Data) {
        terminal.feed(buffer: ArraySlice(data))
        refreshSnapshot()
    }

    public func feed(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        feed(data: data)
    }

    public func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        refreshSnapshot()
    }

    public func drainOutboundData() -> Data {
        terminalDelegate.drainOutboundData()
    }

    private func refreshSnapshot() {
        var snapshot: [String] = []
        var styledSnapshot: [[TerminalStyledCell]] = []
        snapshot.reserveCapacity(terminal.rows)
        styledSnapshot.reserveCapacity(terminal.rows)

        for row in 0..<terminal.rows {
            var line = ""
            var styledLine: [TerminalStyledCell] = []
            line.reserveCapacity(terminal.cols)
            styledLine.reserveCapacity(terminal.cols)
            for col in 0..<terminal.cols {
                guard let charData = terminal.getCharData(col: col, row: row) else {
                    line.append(" ")
                    styledLine.append(
                        TerminalStyledCell(
                            scalar: " ",
                            columnWidth: 1,
                            style: TerminalCellStyle(
                                foreground: terminalDefaultForeground(),
                                background: terminalDefaultBackground()
                            )
                        )
                    )
                    continue
                }
                let scalar: String
                if charData.width == 0 {
                    scalar = " "
                } else {
                    scalar = String(terminal.getCharacter(for: charData))
                }
                line.append(contentsOf: scalar)
                styledLine.append(
                    TerminalStyledCell(
                        scalar: scalar,
                        columnWidth: Int(charData.width),
                        style: style(for: charData.attribute)
                    )
                )
            }
            snapshot.append(line)
            styledSnapshot.append(styledLine)
        }

        rows = snapshot
        styledRows = styledSnapshot
        cursor = (row: terminal.buffer.y, col: terminal.buffer.x)
        columns = terminal.cols
        rowCount = terminal.rows
        isAlternateBufferActive = terminal.isCurrentBufferAlternate
        isApplicationCursorModeActive = terminal.applicationCursor
        isBracketedPasteModeActive = terminal.bracketedPasteMode
        kittyKeyboardFlagsRawValue = terminal.keyboardEnhancementFlags.rawValue
        switch terminal.mouseMode {
        case .off: mouseReportingMode = .off
        case .x10: mouseReportingMode = .x10
        case .vt200: mouseReportingMode = .vt200
        case .buttonEventTracking: mouseReportingMode = .buttonEventTracking
        case .anyEvent: mouseReportingMode = .anyEvent
        }
    }

    private func style(for attribute: Attribute) -> TerminalCellStyle {
        var fg = resolveForegroundColor(attribute.fg)
        var bg = resolveBackgroundColor(attribute.bg)

        if attribute.style.contains(.inverse) {
            let inverseForeground = bg ?? terminalDefaultBackground()
            bg = fg
            fg = inverseForeground
        }

        if attribute.style.contains(.invisible) {
            fg = bg ?? terminalDefaultBackground()
        }

        return TerminalCellStyle(
            foreground: fg,
            background: bg,
            isBold: attribute.style.contains(.bold),
            isUnderlined: attribute.style.contains(.underline),
            isBlinking: attribute.style.contains(.blink),
            isInverse: attribute.style.contains(.inverse),
            isInvisible: attribute.style.contains(.invisible),
            isDim: attribute.style.contains(.dim),
            isItalic: attribute.style.contains(.italic),
            isCrossedOut: attribute.style.contains(.crossedOut),
            underlineStyleRawValue: attribute.underlineStyle.rawValue
        )
    }

    private func resolveForegroundColor(_ color: Attribute.Color) -> TerminalRGBColor {
        switch color {
        case .ansi256(let code):
            return ansi256Color(code)
        case .trueColor(let red, let green, let blue):
            return TerminalRGBColor(red: red, green: green, blue: blue)
        case .defaultColor:
            return terminalDefaultForeground()
        case .defaultInvertedColor:
            return terminalDefaultBackground()
        }
    }

    private func resolveBackgroundColor(_ color: Attribute.Color) -> TerminalRGBColor? {
        switch color {
        case .ansi256(let code):
            return ansi256Color(code)
        case .trueColor(let red, let green, let blue):
            return TerminalRGBColor(red: red, green: green, blue: blue)
        case .defaultColor, .defaultInvertedColor:
            // Let the glass window show through unless a true background is requested.
            return nil
        }
    }

    private func terminalDefaultForeground() -> TerminalRGBColor {
        toRGB(terminal.foregroundColor)
    }

    private func terminalDefaultBackground() -> TerminalRGBColor {
        toRGB(terminal.backgroundColor)
    }

    private func toRGB(_ color: Color) -> TerminalRGBColor {
        TerminalRGBColor(
            red: UInt8(color.red / 257),
            green: UInt8(color.green / 257),
            blue: UInt8(color.blue / 257)
        )
    }

    private func ansi256Color(_ code: UInt8) -> TerminalRGBColor {
        if code < 16 {
            return ansi16Color(code)
        }

        if code < 232 {
            let value = Int(code - 16)
            let r = value / 36
            let g = (value % 36) / 6
            let b = value % 6
            let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
            return TerminalRGBColor(red: steps[r], green: steps[g], blue: steps[b])
        }

        let gray = UInt8(8 + (Int(code) - 232) * 10)
        return TerminalRGBColor(red: gray, green: gray, blue: gray)
    }

    private func ansi16Color(_ code: UInt8) -> TerminalRGBColor {
        let palette: [TerminalRGBColor] = [
            .init(red: 0, green: 0, blue: 0),
            .init(red: 205, green: 0, blue: 0),
            .init(red: 0, green: 205, blue: 0),
            .init(red: 205, green: 205, blue: 0),
            .init(red: 0, green: 0, blue: 238),
            .init(red: 205, green: 0, blue: 205),
            .init(red: 0, green: 205, blue: 205),
            .init(red: 229, green: 229, blue: 229),
            .init(red: 127, green: 127, blue: 127),
            .init(red: 255, green: 0, blue: 0),
            .init(red: 0, green: 255, blue: 0),
            .init(red: 255, green: 255, blue: 0),
            .init(red: 92, green: 92, blue: 255),
            .init(red: 255, green: 0, blue: 255),
            .init(red: 0, green: 255, blue: 255),
            .init(red: 255, green: 255, blue: 255),
        ]
        return palette[Int(code)]
    }
}
