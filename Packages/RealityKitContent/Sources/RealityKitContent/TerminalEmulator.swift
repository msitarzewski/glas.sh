import Foundation
import SwiftTerm

private final class NoOpTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
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

    public init(foreground: TerminalRGBColor, background: TerminalRGBColor?) {
        self.foreground = foreground
        self.background = background
    }
}

public struct TerminalStyledCell: Equatable, Sendable {
    public var scalar: String
    public var style: TerminalCellStyle

    public init(scalar: String, style: TerminalCellStyle) {
        self.scalar = scalar
        self.style = style
    }
}

@MainActor
public final class TerminalEmulator {
    private let terminal: Terminal
    public private(set) var rows: [String] = []
    public private(set) var styledRows: [[TerminalStyledCell]] = []
    public private(set) var cursor: (row: Int, col: Int) = (0, 0)

    public init(cols: Int = 120, rows: Int = 40) {
        terminal = Terminal(delegate: NoOpTerminalDelegate(), options: TerminalOptions())
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

        return TerminalCellStyle(foreground: fg, background: bg)
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
