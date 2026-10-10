import Foundation
import SwiftLensSandbox

#if os(macOS)
import AppKit
#endif

/// A live, interactive preview shown by the agent in its own window (so a crashing preview never takes down
/// the SwiftLens app).
public struct LiveWindowJob: Codable, Sendable {
    public var libraryPath: String
    public var previewIndex: Int
    public var variant: RenderVariant
    public var title: String
    /// x, y, width, height in screen coordinates; `nil` centres the window.
    public var frame: [Double]?

    public init(libraryPath: String, previewIndex: Int, variant: RenderVariant, title: String, frame: [Double]? = nil) {
        self.libraryPath = libraryPath
        self.previewIndex = previewIndex
        self.variant = variant
        self.title = title
        self.frame = frame
    }
}

public enum RenderAgentError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case loadFailed(String)
    case missingSymbol(String)
    case abiMismatch(Int32)

    public var description: String {
        switch self {
        case .unsupportedPlatform: "Rendering SwiftUI requires macOS"
        case .loadFailed(let message): "Could not load preview library: \(message)"
        case .missingSymbol(let symbol): "Preview library is missing \(symbol) (stale cache? delete ~/Library/Caches/SwiftLens)"
        case .abiMismatch(let version): "Preview library ABI v\(version) does not match this SwiftLens (v\(HarnessGenerator.abiVersion))"
        }
    }
}

/// The code that runs *inside* the sandboxed render process. Both the CLI and the app binary act as the agent
/// when launched with ``flag``; the job arrives as JSON on stdin and results leave as JSON on stdout.
public enum RenderAgent {
    public static let flag = "--swiftlens-render-agent"
    public static let liveFlag = "--swiftlens-live-window"

    /// Call first thing in `main`. Returns `false` if this process is not an agent.
    public static func handleCommandLine(_ arguments: [String] = CommandLine.arguments) -> Bool {
        if arguments.contains(flag) {
            runBatchFromStandardInput()
        }
        if let index = arguments.firstIndex(of: liveFlag), index + 1 < arguments.count {
            runLiveWindow(jobPath: arguments[index + 1])
        }
        return false
    }

    static func readStandardInput() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    static func write(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    static func runBatchFromStandardInput() -> Never {
        guard let job = try? JSONDecoder().decode(RenderJob.self, from: readStandardInput()) else {
            FileHandle.standardError.write(Data("swiftlens agent: invalid job\n".utf8))
            exit(2)
        }
        do {
            write(try render(job))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(3)
        }
    }

    #if os(macOS)
    typealias CountFunction = @convention(c) () -> Int32
    typealias NameFunction = @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
    typealias RenderFunction = @convention(c) (Int32, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias MakeViewFunction = @convention(c) (Int32, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias VersionFunction = @convention(c) () -> Int32

    struct Library {
        let handle: UnsafeMutableRawPointer
        let count: CountFunction
        let name: NameFunction
        let render: RenderFunction
        let makeView: MakeViewFunction

        init(path: String) throws {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                throw RenderAgentError.loadFailed(String(cString: dlerror()))
            }
            func symbol<T>(_ name: String, as type: T.Type) throws -> T {
                guard let pointer = dlsym(handle, name) else { throw RenderAgentError.missingSymbol(name) }
                return unsafeBitCast(pointer, to: type)
            }
            let version = try symbol(HarnessGenerator.Symbol.abiVersion, as: VersionFunction.self)()
            guard version == HarnessGenerator.abiVersion else { throw RenderAgentError.abiMismatch(version) }
            self.handle = handle
            count = try symbol(HarnessGenerator.Symbol.previewCount, as: CountFunction.self)
            name = try symbol(HarnessGenerator.Symbol.previewName, as: NameFunction.self)
            render = try symbol(HarnessGenerator.Symbol.renderPNG, as: RenderFunction.self)
            makeView = try symbol(HarnessGenerator.Symbol.makeNSView, as: MakeViewFunction.self)
        }

        func previewName(_ index: Int) -> String {
            guard let pointer = name(Int32(index)) else { return "Preview \(index + 1)" }
            defer { free(pointer) }
            return String(cString: pointer)
        }
    }

    struct HarnessResult: Decodable {
        var pixelWidth: Int
        var pixelHeight: Int
        var pointWidth: Double
        var pointHeight: Double
        var error: String?
    }

    static func encodeVariant(_ variant: RenderVariant) -> String {
        String(decoding: (try? JSONEncoder().encode(variant)) ?? Data("{}".utf8), as: UTF8.self)
    }
    #endif

    /// Renders every requested preview in every variant. Runs on the main thread of the agent process.
    public static func render(_ job: RenderJob) throws -> [RenderOutput] {
        #if os(macOS)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let library = try Library(path: job.libraryPath)
        let count = Int(library.count())
        let indices = job.previewIndices.isEmpty ? Array(0..<count) : job.previewIndices.filter { $0 < count }
        try FileManager.default.createDirectory(atPath: job.outputDirectory, withIntermediateDirectories: true)

        var outputs: [RenderOutput] = []
        for index in indices {
            let name = library.previewName(index)
            let traits = index < job.traits.count ? job.traits[index] : []
            for variant in job.variants {
                let effective = variant.applying(traits)
                let fileName = "preview-\(index)-\(sanitize(variant.label)).png"
                let path = (job.outputDirectory as NSString).appendingPathComponent(fileName)
                let started = DispatchTime.now()
                let raw = encodeVariant(effective).withCString { config in
                    path.withCString { output in library.render(Int32(index), config, output) }
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                var output = RenderOutput(previewIndex: index, previewName: name, variant: effective, imagePath: nil, durationMilliseconds: elapsed)
                if let raw {
                    defer { free(raw) }
                    if let result = try? JSONDecoder().decode(HarnessResult.self, from: Data(String(cString: raw).utf8)) {
                        output.pixelWidth = result.pixelWidth
                        output.pixelHeight = result.pixelHeight
                        output.pointWidth = result.pointWidth
                        output.pointHeight = result.pointHeight
                        output.error = result.error
                        if result.error == nil { output.imagePath = path }
                    }
                } else {
                    output.error = "Renderer returned no result"
                }
                outputs.append(output)
            }
        }
        return outputs
        #else
        throw RenderAgentError.unsupportedPlatform
        #endif
    }

    static func sanitize(_ label: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(label.map { allowed.contains($0) ? $0 : "_" })
        return mapped.isEmpty ? "default" : mapped
    }

    static func runLiveWindow(jobPath: String) -> Never {
        #if os(macOS)
        guard let data = FileManager.default.contents(atPath: jobPath),
              let job = try? JSONDecoder().decode(LiveWindowJob.self, from: data) else {
            FileHandle.standardError.write(Data("swiftlens agent: invalid live job\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            let library = try Library(path: job.libraryPath)
            let config = encodeVariant(job.variant)
            guard let pointer = config.withCString({ library.makeView(Int32(job.previewIndex), $0) }) else {
                throw RenderAgentError.missingSymbol(HarnessGenerator.Symbol.makeNSView)
            }
            let view = Unmanaged<NSView>.fromOpaque(pointer).takeRetainedValue()
            let size = view.fittingSize
            let initial = NSRect(
                x: 0, y: 0,
                width: job.variant.width ?? max(size.width, 240),
                height: job.variant.height ?? max(size.height, 160)
            )
            let window = NSWindow(contentRect: initial, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "SwiftLens Live — \(job.title)"
            window.contentView = view
            window.isReleasedWhenClosed = false
            if let frame = job.frame, frame.count == 4 {
                window.setFrame(NSRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), display: true)
            } else {
                window.center()
            }
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            // Report the frame whenever it changes so the host can reopen the window in the same place.
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { _ in
                reportFrame(window)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
                reportFrame(window)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                exit(0)
            }
            // Exit when the host goes away (we get re-parented to launchd).
            let parent = getppid()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                if getppid() != parent { exit(0) }
            }
            app.run()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(3)
        }
        #else
        FileHandle.standardError.write(Data("Rendering SwiftUI requires macOS\n".utf8))
        exit(4)
        #endif
    }

    #if os(macOS)
    static func reportFrame(_ window: NSWindow) {
        let frame = window.frame
        write(["frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]])
    }
    #endif
}
