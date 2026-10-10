import Foundation
import SwiftLensCore
import SwiftSyntax

public enum SnippetCompilerError: Error, CustomStringConvertible {
    case noCompiler
    case unsupportedPlatform
    case compilationFailed([LensDiagnostic], log: String)
    case timedOut(Double)

    public var description: String {
        switch self {
        case .noCompiler: "swiftc not found (install Xcode or set SWIFTLENS_TOOLCHAIN)"
        case .unsupportedPlatform: "Rendering SwiftUI requires macOS"
        case .compilationFailed(let diagnostics, let log):
            diagnostics.isEmpty ? "Compilation failed:\n\(log)" : diagnostics.map(\.description).joined(separator: "\n")
        case .timedOut(let seconds): "Compilation timed out after \(Int(seconds))s"
        }
    }
}

/// Compiles a snippet plus its generated harness into a dylib, with a content-addressed cache so that
/// re-rendering unchanged code is instant.
public struct SnippetCompiler: Sendable {
    public struct Options: Sendable {
        public var swiftcPath: String?
        public var sdkPath: String?
        public var cacheDirectory: URL
        /// Extra flags, e.g. `-F`, `-I`, `-L`, `-l` for your own frameworks.
        public var extraArguments: [String] = []
        /// e.g. `14.0`. Defaults to the running OS so new SwiftUI APIs are available.
        public var deploymentTarget: String?
        public var optimize: Bool = false
        public var timeout: Double = 120

        public init(swiftcPath: String? = nil, sdkPath: String? = nil, cacheDirectory: URL = SnippetCompiler.defaultCacheDirectory, extraArguments: [String] = [], deploymentTarget: String? = nil, optimize: Bool = false, timeout: Double = 120) {
            self.swiftcPath = swiftcPath
            self.sdkPath = sdkPath
            self.cacheDirectory = cacheDirectory
            self.extraArguments = extraArguments
            self.deploymentTarget = deploymentTarget
            self.optimize = optimize
            self.timeout = timeout
        }
    }

    public struct Output: Sendable {
        public var libraryPath: String
        public var moduleName: String
        public var entries: [PreviewEntry]
        public var warnings: [LensDiagnostic]
        public var durationMilliseconds: Double
        public var cacheHit: Bool
        public var commandLine: [String]
    }

    public static var defaultCacheDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? (NSHomeDirectory() + "/.cache"))
        #endif
        return base.appendingPathComponent("SwiftLens/Renders", isDirectory: true)
    }

    public var options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// The swiftc invocation for the given sources (exposed for tests, `--dry-run` and bug reports).
    public func commandLine(sources: [String], output: String, moduleName: String) -> [String] {
        var arguments = [
            options.swiftcPath ?? "swiftc",
            "-emit-library",
            "-parse-as-library",
            "-module-name", moduleName,
            "-swift-version", "5",
            options.optimize ? "-O" : "-Onone",
            "-o", output,
        ]
        if let sdk = options.sdkPath { arguments += ["-sdk", sdk] }
        arguments += ["-target", "\(Self.hostArchitecture)-apple-macos\(options.deploymentTarget ?? Self.hostOSVersion)"]
        arguments += options.extraArguments
        arguments += sources
        return arguments
    }

    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    public static var hostOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "\(max(version.majorVersion, 13)).\(version.majorVersion >= 13 ? version.minorVersion : 0)"
        #else
        return "14.0"
        #endif
    }

    /// Writes the sources to a cache directory keyed by content hash and compiles them (unless cached).
    public func compile(_ document: SourceDocument) throws -> Output {
        let started = DispatchTime.now()
        let key = Self.hash([document.text, options.extraArguments.joined(separator: " "), options.swiftcPath ?? "", options.sdkPath ?? "", options.deploymentTarget ?? Self.hostOSVersion, String(HarnessGenerator.abiVersion), options.optimize ? "O" : "Onone"].joined(separator: "\u{0}"))
        let directory = options.cacheDirectory.appendingPathComponent(key, isDirectory: true)
        let snippetPath = directory.appendingPathComponent("Snippet.swift").path
        let harnessPath = directory.appendingPathComponent("SwiftLensHarness.swift").path
        let moduleName = "SwiftLensSnippet_\(key)"
        let libraryPath = directory.appendingPathComponent("lib\(moduleName).dylib").path

        let harness = HarnessGenerator.generate(document, snippetPath: snippetPath)
        let command = commandLine(sources: [snippetPath, harnessPath], output: libraryPath, moduleName: moduleName)

        if FileManager.default.fileExists(atPath: libraryPath) {
            return Output(libraryPath: libraryPath, moduleName: moduleName, entries: harness.entries, warnings: [], durationMilliseconds: Self.elapsed(since: started), cacheHit: true, commandLine: command)
        }

        #if !os(macOS)
        throw SnippetCompilerError.unsupportedPlatform
        #else
        guard let swiftc = options.swiftcPath else { throw SnippetCompilerError.noCompiler }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try harness.snippetSource.write(toFile: snippetPath, atomically: true, encoding: .utf8)
        try harness.harnessSource.write(toFile: harnessPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftc)
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + options.timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let log = String(decoding: data, as: UTF8.self)
        let diagnostics = Self.parseDiagnostics(log, snippetPath: snippetPath, document: document)

        if process.terminationReason == .uncaughtSignal { throw SnippetCompilerError.timedOut(options.timeout) }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: libraryPath) else {
            throw SnippetCompilerError.compilationFailed(diagnostics, log: log)
        }
        return Output(libraryPath: libraryPath, moduleName: moduleName, entries: harness.entries, warnings: diagnostics, durationMilliseconds: Self.elapsed(since: started), cacheHit: false, commandLine: command)
        #endif
    }

    /// Parses `file:line:col: severity: message` lines. Locations in the snippet (including preview bodies, thanks to
    /// `#sourceLocation`) are mapped onto the original document; harness-internal ones are kept without a position.
    public static func parseDiagnostics(_ log: String, snippetPath: String, document: SourceDocument) -> [LensDiagnostic] {
        var diagnostics: [LensDiagnostic] = []
        for line in log.split(separator: "\n") {
            guard let match = parseDiagnosticLine(String(line)) else { continue }
            var position: SourcePosition?
            if match.file == snippetPath || (match.file as NSString).lastPathComponent == "Snippet.swift" {
                let absolute = document.converter.position(ofLine: match.line, column: match.column)
                position = SourcePosition(line: match.line, column: match.column, offset: absolute.utf8Offset)
            }
            if match.severity == .note, var last = diagnostics.popLast() {
                last.notes.append(match.message)
                diagnostics.append(last)
                continue
            }
            diagnostics.append(LensDiagnostic(severity: match.severity, message: match.message, position: position, origin: .compiler))
        }
        return diagnostics
    }

    static func parseDiagnosticLine(_ line: String) -> (file: String, line: Int, column: Int, severity: LensSeverity, message: String)? {
        for severity in [LensSeverity.error, .warning, .note] {
            let marker = ": \(severity.rawValue): "
            guard let markerRange = line.range(of: marker) else { continue }
            let location = line[..<markerRange.lowerBound]
            let parts = location.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 3, let column = Int(parts[parts.count - 1]), let lineNumber = Int(parts[parts.count - 2]) else { continue }
            let file = parts[..<(parts.count - 2)].joined(separator: ":")
            return (file, lineNumber, column, severity, String(line[markerRange.upperBound...]))
        }
        return nil
    }

    static func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    static func hash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }
}
