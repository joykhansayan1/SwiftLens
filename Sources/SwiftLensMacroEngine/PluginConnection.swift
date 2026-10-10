import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PluginConnectionError: Error, CustomStringConvertible {
    case launchFailed(String, underlying: Error)
    case pluginExited(String, stderr: String)
    case timedOut(String, seconds: Double)
    case malformedResponse(String)
    case unexpectedResponse(String)
    case libraryLoadFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .launchFailed(let path, let error): "Could not launch macro plugin \(path): \(error)"
        case .pluginExited(let path, let stderr):
            "Macro plugin \(path) exited unexpectedly" + (stderr.isEmpty ? "" : ":\n\(stderr)")
        case .timedOut(let path, let seconds): "Macro plugin \(path) did not answer within \(Int(seconds))s"
        case .malformedResponse(let detail): "Malformed response from macro plugin: \(detail)"
        case .unexpectedResponse(let detail): "Unexpected response from macro plugin: \(detail)"
        case .libraryLoadFailed(let path, let message): "Plugin server could not load \(path): \(message)"
        }
    }
}

/// A running macro plugin process that speaks the compiler's plugin protocol over stdin/stdout.
///
/// The same type drives both executable plugins (`-load-plugin-executable`) and the toolchain's
/// `swift-plugin-server`, which hosts library plugins (`lib*Macros.dylib/.so`) such as Observation or SwiftUI.
public final class PluginConnection {
    public let executablePath: String
    public private(set) var capability: (protocolVersion: Int, features: [String])?
    public var timeout: Double

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrBuffer = LockedBuffer()
    private let lock = NSLock()
    private var loadedLibraries: Set<String> = []

    public init(executablePath: String, arguments: [String] = [], timeout: Double = 20) throws {
        Self.ignoreSIGPIPE
        self.executablePath = executablePath
        self.timeout = timeout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let buffer = stderrBuffer
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }
        do {
            try process.run()
        } catch {
            throw PluginConnectionError.launchFailed(executablePath, underlying: error)
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        let response = try request(.getCapability(capability: .init(protocolVersion: PluginWire.protocolVersion)))
        guard case .getCapabilityResult(let capability) = response else {
            throw PluginConnectionError.unexpectedResponse("expected getCapabilityResult")
        }
        self.capability = (capability.protocolVersion, capability.features ?? [])
    }

    deinit {
        shutdown()
    }

    public var isRunning: Bool { process.isRunning }

    public var supportsLibraryLoading: Bool {
        capability?.features.contains("load-plugin-library") ?? false
    }

    /// Everything the plugin wrote to stderr so far (useful when a plugin crashes).
    public var standardError: String { stderrBuffer.string }

    public func shutdown() {
        if process.isRunning {
            try? stdinHandle.close()
            process.terminate()
        }
    }

    /// Asks a plugin server to `dlopen` a library plugin. Idempotent per path.
    public func loadLibrary(path: String, moduleName: String) throws {
        if loadedLibraries.contains(path) { return }
        let response = try request(.loadPluginLibrary(libraryPath: path, moduleName: moduleName))
        guard case .loadPluginLibraryResult(let loaded, let diagnostics) = response else {
            throw PluginConnectionError.unexpectedResponse("expected loadPluginLibraryResult")
        }
        guard loaded else {
            throw PluginConnectionError.libraryLoadFailed(path: path, message: diagnostics.map(\.message).joined(separator: "; "))
        }
        loadedLibraries.insert(path)
    }

    func request(_ message: HostToPluginMessage) throws -> PluginToHostMessage {
        lock.lock()
        defer { lock.unlock() }

        let payload = try JSONEncoder().encode(message)
        var header = UInt64(payload.count).littleEndian
        var frame = Data(bytes: &header, count: 8)
        frame.append(payload)

        // A watchdog terminates hung plugins; the blocked read then sees EOF.
        let fired = LockedBuffer()
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning {
                fired.append(Data([1]))
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        do {
            try stdinHandle.write(contentsOf: frame)
        } catch {
            throw PluginConnectionError.pluginExited(executablePath, stderr: standardError)
        }

        guard let sizeData = readExactly(8) else {
            if !fired.isEmpty {
                throw PluginConnectionError.timedOut(executablePath, seconds: timeout)
            }
            throw PluginConnectionError.pluginExited(executablePath, stderr: standardError)
        }
        let size = sizeData.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard size < 512 * 1024 * 1024 else {
            throw PluginConnectionError.malformedResponse("implausible message size \(size)")
        }
        guard let body = readExactly(Int(size)) else {
            throw PluginConnectionError.pluginExited(executablePath, stderr: standardError)
        }
        do {
            return try JSONDecoder().decode(PluginToHostMessage.self, from: body)
        } catch {
            throw PluginConnectionError.malformedResponse("\(error) — \(String(decoding: body.prefix(400), as: UTF8.self))")
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try? stdoutHandle.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

/// Thread-safe byte buffer used to collect a plugin's stderr.
final class LockedBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 256 * 1024 { data = data.suffix(128 * 1024) }
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
