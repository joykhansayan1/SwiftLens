import Foundation
import SwiftLensCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum Terminal {
    static let colorEnabled: Bool = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func paint(_ text: String, _ code: String) -> String {
        colorEnabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { paint(text, "1") }
    static func dim(_ text: String) -> String { paint(text, "2") }
    static func red(_ text: String) -> String { paint(text, "31") }
    static func green(_ text: String) -> String { paint(text, "32") }
    static func yellow(_ text: String) -> String { paint(text, "33") }
    static func blue(_ text: String) -> String { paint(text, "34") }
    static func magenta(_ text: String) -> String { paint(text, "35") }
    static func cyan(_ text: String) -> String { paint(text, "36") }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data((red("error: ") + message + "\n").utf8))
    }

    static func printDiagnostic(_ diagnostic: LensDiagnostic, fileName: String) {
        let location = diagnostic.position.map { "\(fileName):\($0.line):\($0.column): " } ?? "\(fileName): "
        let severity: String
        switch diagnostic.severity {
        case .error: severity = red("error")
        case .warning: severity = yellow("warning")
        case .note, .remark: severity = cyan(diagnostic.severity.rawValue)
        }
        let macro = diagnostic.macroName.map { dim(" [\($0)]") } ?? ""
        print("\(location)\(severity): \(diagnostic.message)\(macro)")
        for note in diagnostic.notes { print("  " + cyan("note: ") + note) }
        for fixIt in diagnostic.fixIts { print("  " + green("fix-it: ") + fixIt.message) }
    }

    static func colorizedDiff(_ diff: String) -> String {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.hasPrefix("+++") || line.hasPrefix("---") { return bold(String(line)) }
            if line.hasPrefix("@@") { return cyan(String(line)) }
            if line.hasPrefix("+") { return green(String(line)) }
            if line.hasPrefix("-") { return red(String(line)) }
            return String(line)
        }.joined(separator: "\n")
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Reads a file argument, `-` meaning stdin.
func readSource(_ path: String) throws -> (text: String, name: String) {
    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), "stdin.swift")
    }
    return (try String(contentsOfFile: path, encoding: .utf8), path)
}
