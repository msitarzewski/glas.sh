#if os(macOS)
import AppKit
import Foundation

enum TerminalThemeImportError: LocalizedError {
    case emptyInput
    case inputTooLarge(maximumBytes: Int)
    case unsupportedFileExtension
    case invalidPropertyList
    case invalidRootObject
    case invalidValue(key: String)
    case invalidArchive(key: String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The Terminal profile is empty."
        case .inputTooLarge(let maximumBytes):
            return "The Terminal profile exceeds the \(maximumBytes)-byte import limit."
        case .unsupportedFileExtension:
            return "Choose a .terminal profile."
        case .invalidPropertyList:
            return "The Terminal profile is not a valid property list."
        case .invalidRootObject:
            return "The Terminal profile must contain one settings dictionary."
        case .invalidValue(let key):
            return "The Terminal profile contains an invalid value for \(key)."
        case .invalidArchive(let key):
            return "The Terminal profile contains an invalid secure archive for \(key)."
        }
    }
}

@MainActor
enum TerminalThemeImportService {
    static let maximumImportBytes = 1_048_576
    static let maximumNameLength = TerminalTheme.maximumNameLength

    private static let colorFields: [(String, WritableKeyPath<TerminalTheme, CodableColor>)] = [
        ("TextColor", \.foreground),
        ("CursorColor", \.cursor),
        ("SelectionColor", \.selection),
        ("ANSIBlackColor", \.black),
        ("ANSIRedColor", \.red),
        ("ANSIGreenColor", \.green),
        ("ANSIYellowColor", \.yellow),
        ("ANSIBlueColor", \.blue),
        ("ANSIMagentaColor", \.magenta),
        ("ANSICyanColor", \.cyan),
        ("ANSIWhiteColor", \.white),
        ("ANSIBrightBlackColor", \.brightBlack),
        ("ANSIBrightRedColor", \.brightRed),
        ("ANSIBrightGreenColor", \.brightGreen),
        ("ANSIBrightYellowColor", \.brightYellow),
        ("ANSIBrightBlueColor", \.brightBlue),
        ("ANSIBrightMagentaColor", \.brightMagenta),
        ("ANSIBrightCyanColor", \.brightCyan),
        ("ANSIBrightWhiteColor", \.brightWhite),
    ]

    static func importTheme(from url: URL, fallback: TerminalTheme) throws -> TerminalTheme {
        guard url.isFileURL, url.pathExtension.lowercased() == "terminal" else {
            throw TerminalThemeImportError.unsupportedFileExtension
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumImportBytes + 1) ?? Data()
        return try importTheme(from: data, fallback: fallback)
    }

    static func importTheme(from data: Data, fallback: TerminalTheme) throws -> TerminalTheme {
        guard !data.isEmpty else { throw TerminalThemeImportError.emptyInput }
        guard data.count <= maximumImportBytes else {
            throw TerminalThemeImportError.inputTooLarge(maximumBytes: maximumImportBytes)
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw TerminalThemeImportError.invalidPropertyList
        }
        guard let profile = propertyList as? [String: Any] else {
            throw TerminalThemeImportError.invalidRootObject
        }

        var imported = fallback
        // macOS 27 Terminal's registered default profile is Clear Dark. Older
        // built-ins such as Homebrew intentionally omit ANSI fields and inherit
        // that palette; they must not inherit whichever glas.sh theme happened
        // to be selected when the user imported them.
        imported.applyAppleClearDarkColors()
        if let rawName = profile["name"] {
            guard let name = rawName as? String else {
                throw TerminalThemeImportError.invalidValue(key: "name")
            }
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName.count <= maximumNameLength,
                  !trimmedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TerminalThemeImportError.invalidValue(key: "name")
            }
            imported.name = trimmedName
        }

        for (key, keyPath) in colorFields {
            guard let value = profile[key] else { continue }
            guard let archivedColor = value as? Data else {
                throw TerminalThemeImportError.invalidValue(key: key)
            }
            imported[keyPath: keyPath] = try decodeColor(archivedColor, key: key)
        }

        // The profile background itself remains excluded from the imported
        // canvas color, but its luminance tells us whether Apple's palette was
        // designed for a light or dark surface. Preserve that semantic so the
        // adjustable glass material does not switch to a pale compositor when
        // macOS changes appearance and wash out a dark terminal palette.
        if let archivedBackground = profile["BackgroundColor"] as? Data,
           let profileBackground = try? decodeColor(
               archivedBackground,
               key: "BackgroundColor"
           ) {
            let luminance = (0.2126 * profileBackground.red)
                + (0.7152 * profileBackground.green)
                + (0.0722 * profileBackground.blue)
            imported.preferredAppearance = luminance < 0.5 ? .dark : .light
        }

        if let value = profile["Font"] {
            guard let archivedFont = value as? Data else {
                throw TerminalThemeImportError.invalidValue(key: "Font")
            }
            let font = try decodeFont(archivedFont)
            // Apple's built-in profiles use `.AppleSystemUIFont` as a sentinel
            // for Terminal's default font. Never turn that into proportional
            // terminal text; keep the user's fallback monospaced family.
            if font.isFixedPitch {
                imported.fontName = font.fontName
            }
            imported.fontSize = font.pointSize
        }

        // Background color, blur, commands, directories, shell behavior,
        // dimensions, and every other profile field remain outside the
        // allowlist. Only the background's light/dark semantic is retained.
        imported.background = fallback.background
        return imported
    }

    private static func decodeColor(_ data: Data, key: String) throws -> CodableColor {
        let color: NSColor
        do {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSColor.self,
                from: data
            ) else {
                throw TerminalThemeImportError.invalidArchive(key: key)
            }
            color = decoded
        } catch is TerminalThemeImportError {
            throw TerminalThemeImportError.invalidArchive(key: key)
        } catch {
            throw TerminalThemeImportError.invalidArchive(key: key)
        }

        guard let sRGB = color.usingColorSpace(.sRGB) else {
            throw TerminalThemeImportError.invalidValue(key: key)
        }
        let components = [
            Double(sRGB.redComponent),
            Double(sRGB.greenComponent),
            Double(sRGB.blueComponent),
            Double(sRGB.alphaComponent),
        ]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw TerminalThemeImportError.invalidValue(key: key)
        }
        return CodableColor(
            sRGBRed: components[0],
            green: components[1],
            blue: components[2],
            alpha: components[3]
        )
    }

    private static func decodeFont(_ data: Data) throws -> NSFont {
        let font: NSFont
        do {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSFont.self,
                from: data
            ) else {
                throw TerminalThemeImportError.invalidArchive(key: "Font")
            }
            font = decoded
        } catch is TerminalThemeImportError {
            throw TerminalThemeImportError.invalidArchive(key: "Font")
        } catch {
            throw TerminalThemeImportError.invalidArchive(key: "Font")
        }

        guard !font.fontName.isEmpty,
              font.fontName.count <= TerminalTheme.maximumFontNameLength,
              font.pointSize.isFinite,
              (TerminalTheme.minimumFontSize...TerminalTheme.maximumFontSize).contains(font.pointSize) else {
            throw TerminalThemeImportError.invalidValue(key: "Font")
        }
        return font
    }
}
#endif
