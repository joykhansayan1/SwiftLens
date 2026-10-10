import Foundation
import SwiftLensCore
import SwiftLensSandbox

/// Launches the render agent as a child process: user code runs there, so an infinite loop, a `fatalError`
/// or a stack overflow in a preview is reported as an error instead of crashing SwiftLens.
public struct RenderClient: Sendable {
    /// Executable that understands ``RenderAgent/flag`` (the `swiftlens` CLI or the SwiftLens app binary).
    public var agentExecutable: String

    public init(agentExecutable: String = RenderClient.currentExecutable) {
        self.agentExecutable = agentExecutable
    }

    public static var currentExecutable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    public struct Result: Sendable {
        public var outputs: [RenderOutput]
        public var failure: String?
        public var durationMilliseconds: Double
    }

    public func render(_ job: RenderJob) -> Result {
        let started = DispatchTime.now()
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000 }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentExecutable)
        process.arguments = [RenderAgent.flag]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return Result(outputs: [], failure: "Could not launch render agent \(agentExecutable): \(error)", durationMilliseconds: elapsed())
        }
        let payload = (try? JSONEncoder().encode(job)) ?? Data()
        try? input.fileHandleForWriting.write(contentsOf: payload)
        try? input.fileHandleForWriting.close()

        let budget = job.timeout * Double(max(1, job.variants.count * max(1, job.previewIndices.count))) + 10
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + budget, execute: watchdog)

        // Drain stderr concurrently so a chatty preview cannot dead-lock the pipe.
        let stderrData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData.data = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        let stderrText = String(decoding: stderrData.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.isSet {
            return Result(outputs: [], failure: "Preview did not finish rendering within \(Int(budget))s (infinite loop or deadlock?) — the render process was terminated.", durationMilliseconds: elapsed())
        }
        if process.terminationStatus != 0 || process.terminationReason == .uncaughtSignal {
            let reason = process.terminationReason == .uncaughtSignal ? "crashed (signal \(process.terminationStatus))" : "exited with status \(process.terminationStatus)"
            let detail = Self.crashSummary(stderrText)
            return Result(outputs: [], failure: "The preview \(reason)." + (detail.isEmpty ? "" : "\n\(detail)"), durationMilliseconds: elapsed())
        }
        guard let outputs = try? JSONDecoder().decode([RenderOutput].self, from: stdoutData) else {
            return Result(outputs: [], failure: "Render agent returned malformed output.\n\(stderrText)", durationMilliseconds: elapsed())
        }
        return Result(outputs: outputs, failure: nil, durationMilliseconds: elapsed())
    }

    /// Picks the interesting lines (Swift runtime errors) out of a crash's stderr.
    static func crashSummary(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let interesting = lines.filter {
            $0.contains("Fatal error") || $0.contains("fatal error") || $0.contains("error:") || $0.contains("Thread ") || $0.contains("Precondition failed")
        }
        return (interesting.isEmpty ? Array(lines.suffix(8)) : Array(interesting.prefix(8))).joined(separator: "\n")
    }

    /// Opens an interactive live window in a separate agent process. Terminate the returned process to close it.
    public func openLiveWindow(_ job: LiveWindowJob, onFrameChange: (@Sendable ([Double]) -> Void)? = nil) throws -> Process {
        let jobFile = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlens-live-\(UUID().uuidString).json")
        try JSONEncoder().encode(job).write(to: jobFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agentExecutable)
        process.arguments = [RenderAgent.liveFlag, jobFile.path]
        let output = Pipe()
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let message = try? JSONDecoder().decode([String: [Double]].self, from: Data(line)), let frame = message["frame"] {
                    onFrameChange?(frame)
                }
            }
        }
        try process.run()
        return process
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Compile + render in one call: the high-level API used by the CLI and the app.
public struct RenderPipeline: Sendable {
    public var compiler: SnippetCompiler
    public var client: RenderClient

    public init(compiler: SnippetCompiler, client: RenderClient = RenderClient()) {
        self.compiler = compiler
        self.client = client
    }

    public func render(_ document: SourceDocument, variants: [RenderVariant], previewIndices: [Int] = [], outputDirectory: String? = nil, timeout: Double = 15) -> (RenderReport, SnippetCompiler.Output?) {
        let compiled: SnippetCompiler.Output
        do {
            compiled = try compiler.compile(document)
        } catch SnippetCompilerError.compilationFailed(let diagnostics, let log) {
            let fallback = diagnostics.isEmpty ? [LensDiagnostic(severity: .error, message: log, position: nil, origin: .compiler)] : diagnostics
            return (RenderReport(compileDiagnostics: fallback), nil)
        } catch {
            return (RenderReport(compileDiagnostics: [LensDiagnostic(severity: .error, message: "\(error)", position: nil, origin: .sandbox)]), nil)
        }
        guard !compiled.entries.isEmpty else {
            return (RenderReport(
                compileDiagnostics: compiled.warnings + [LensDiagnostic(severity: .warning, message: "Nothing to render: add a #Preview { ... } block, a PreviewProvider, or a View with an init() that takes no arguments.", position: nil, origin: .sandbox)],
                compileDurationMilliseconds: compiled.durationMilliseconds,
                cacheHit: compiled.cacheHit
            ), compiled)
        }
        let directory = outputDirectory ?? (compiled.libraryPath as NSString).deletingLastPathComponent + "/renders-\(UUID().uuidString.prefix(8))"
        let job = RenderJob(
            libraryPath: compiled.libraryPath,
            previewIndices: previewIndices,
            variants: variants,
            outputDirectory: directory,
            traits: compiled.entries.map(\.traits),
            timeout: timeout
        )
        let result = client.render(job)
        return (RenderReport(
            outputs: result.outputs,
            compileDiagnostics: compiled.warnings,
            compileDurationMilliseconds: compiled.durationMilliseconds,
            renderDurationMilliseconds: result.durationMilliseconds,
            cacheHit: compiled.cacheHit,
            agentFailure: result.failure
        ), compiled)
    }
}
