import Foundation
import SwiftLensCore

/// One expansion printed by `swiftc -Xfrontend -dump-macro-expansions`.
public struct CompilerExpansion: Codable, Hashable, Sendable {
    /// The mangled buffer name, e.g. `@__swiftmacro_3obs7Counter10ObservablefMm_.swift`.
    public var bufferName: String
    /// Best-effort macro name recovered from the mangling (`Observable`).
    public var macroName: String?
    public var role: MacroDefinition.Role?
    public var expandedSource: String
}

/// Parses the compiler's macro-expansion dump and runs the compiler to produce one.
///
/// SwiftLens' primary engine talks to plugins directly (fast, no build). This compiler path is the ground truth:
/// `swiftlens expand --verify` runs both and reports any difference, which catches cases where a macro
/// depends on semantic information (resolved types, conformances) that only the compiler has.
public enum CompilerExpansionDump {
    static let separator = "------------------------------"

    public static func parse(_ output: String) -> [CompilerExpansion] {
        var results: [CompilerExpansion] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@__swiftmacro_"), index + 1 < lines.count, lines[index + 1] == separator {
                var body: [String] = []
                var cursor = index + 2
                while cursor < lines.count, lines[cursor] != separator {
                    body.append(lines[cursor])
                    cursor += 1
                }
                let buffer = line.trimmingWhitespace()
                let (name, role) = demangle(buffer)
                results.append(CompilerExpansion(bufferName: buffer, macroName: name, role: role, expandedSource: body.joined(separator: "\n")))
                index = cursor + 1
            } else {
                index += 1
            }
        }
        return results
    }

    /// Recovers the macro name and role from a buffer name like `@__swiftmacro_3obs7Counter10ObservablefMm_.swift`.
    static func demangle(_ buffer: String) -> (String?, MacroDefinition.Role?) {
        var mangled = buffer
        if mangled.hasPrefix("@__swiftmacro_") { mangled.removeFirst("@__swiftmacro_".count) }
        if mangled.hasSuffix(".swift") { mangled.removeLast(".swift".count) }
        let characters = Array(mangled)
        // Find the last `fM<role><digits>_` marker.
        var markerIndex: Int?
        var i = characters.count - 1
        while i >= 2 {
            if characters[i - 2] == "f", characters[i - 1] == "M", characters[i].isLetter {
                markerIndex = i - 2
                break
            }
            i -= 1
        }
        guard let marker = markerIndex else { return (nil, nil) }
        let roleCode = characters[marker + 2]
        let role: MacroDefinition.Role? = switch roleCode {
        case "f": .expression // freestanding (expression / declaration / code item)
        case "a": .accessor
        case "r": .memberAttribute
        case "m": .member
        case "p": .peer
        case "c": .conformance
        case "e": .extension
        case "q": .preamble
        case "b": .body
        default: nil
        }
        // The macro name is the length-prefixed identifier immediately before the marker.
        var name: String?
        for start in stride(from: marker - 1, through: 1, by: -1) {
            let length = marker - start
            var digitsStart = start
            while digitsStart > 0, characters[digitsStart - 1].isNumber { digitsStart -= 1 }
            guard digitsStart < start else { continue }
            if let value = Int(String(characters[digitsStart..<start])), value == length {
                name = String(characters[start..<marker])
                break
            }
        }
        return (name, role)
    }

    /// Runs `swiftc -typecheck` with expansion dumping on the given files.
    public static func run(
        files: [String],
        toolchain: Toolchain,
        moduleName: String? = nil,
        extraArguments: [String] = [],
        timeout: Double = 120
    ) throws -> (expansions: [CompilerExpansion], diagnostics: String) {
        guard let swiftc = toolchain.swiftcPath else {
            throw MacroEngineError.expansionFailed("compiler", ["swiftc not found in \(toolchain.root)"])
        }
        var arguments = ["-typecheck", "-Xfrontend", "-dump-macro-expansions"]
        if let sdk = toolchain.sdkPath { arguments += ["-sdk", sdk] }
        // Must match the module name SwiftLens reports to macros, or `#fileID`-based expansions differ.
        if let moduleName { arguments += ["-module-name", moduleName] }
        arguments += extraArguments + files

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftc)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let text = String(decoding: data, as: UTF8.self)
        let expansions = parse(text)
        // Everything that is not part of an expansion block is compiler diagnostics.
        var diagnostics = text
        for expansion in expansions {
            diagnostics = diagnostics.replacingOccurrences(of: "\(expansion.bufferName)\n\(separator)\n\(expansion.expandedSource)\n\(separator)\n", with: "")
        }
        return (expansions, diagnostics.trimmingWhitespace())
    }

    /// Compares SwiftLens' expansions with the compiler's, ignoring whitespace and unique-name mangling.
    public static func verify(report: ExpansionReport, against compiler: [CompilerExpansion]) -> [String] {
        func normalize(_ text: String) -> String {
            let prettified = UniqueNamePrettifier().rewrite(text)
            let withoutUniqueNames = prettified.replacingOccurrences(
                of: #"__[A-Za-z_][A-Za-z0-9_]*_\d+"#, with: "__unique", options: .regularExpression
            )
            return withoutUniqueNames.filter { !$0.isWhitespace }
        }
        var problems: [String] = []
        var remaining = compiler.filter { !$0.expandedSource.trimmingWhitespace().isEmpty }
        for record in report.expansions where !record.expandedSource.trimmingWhitespace().isEmpty {
            let normalized = normalize(record.expandedSource)
            if let match = remaining.firstIndex(where: { normalize($0.expandedSource) == normalized }) {
                remaining.remove(at: match)
            } else {
                problems.append("SwiftLens expansion of \(record.spelling) (\(record.role.rawValue)) has no identical compiler expansion")
            }
        }
        for leftover in remaining {
            problems.append("Compiler produced an expansion SwiftLens did not: \(leftover.macroName ?? leftover.bufferName) (\(leftover.role?.rawValue ?? "?"))")
        }
        return problems
    }
}
