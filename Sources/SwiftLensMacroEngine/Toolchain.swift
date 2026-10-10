import Foundation

/// Locates the Swift toolchain pieces SwiftLens needs: `swift-plugin-server`, library plugin directories,
/// and the module interfaces that declare built-in macros (`@Observable`, `#Preview`, `#Predicate`, `@Test`...).
public struct Toolchain: Codable, Sendable, CustomStringConvertible {
    /// Root of the toolchain, i.e. the directory containing `usr/bin/swift`.
    public var root: String
    public var swiftPath: String?
    public var swiftcPath: String?
    public var pluginServerPath: String?
    /// Directories containing `lib<Module>.dylib|so` library plugins.
    public var pluginDirectories: [String]
    /// Directories searched for `<Module>.swiftmodule/*.swiftinterface` and `<Module>.framework`.
    public var interfaceDirectories: [String]
    /// macOS SDK path, when available.
    public var sdkPath: String?

    public var description: String {
        """
        toolchain root:   \(root)
        swiftc:           \(swiftcPath ?? "not found")
        plugin server:    \(pluginServerPath ?? "not found")
        sdk:              \(sdkPath ?? "n/a")
        plugin dirs:      \(pluginDirectories.joined(separator: "\n                  "))
        interface dirs:   \(interfaceDirectories.joined(separator: "\n                  "))
        """
    }

    /// Modules known to declare macros backed by toolchain/SDK plugins. Scanning only these keeps
    /// discovery fast (a full SDK scan parses hundreds of large interfaces).
    public static let macroDeclaringModules = [
        "Swift", "_Concurrency", "Observation", "Foundation", "FoundationEssentials", "Testing", "SwiftUI",
        "SwiftUICore", "DeveloperToolsSupport", "SwiftData", "Playgrounds", "OSLog", "os", "AppIntents", "TipKit",
        "WidgetKit", "RealityKit", "Synchronization", "CoreData", "Charts", "MapKit", "AVFoundation", "Accessibility",
    ]

    /// Finds the active toolchain. Honours `SWIFTLENS_TOOLCHAIN` (a toolchain root), then `xcrun` on macOS,
    /// then `swift` on `PATH`.
    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> Toolchain? {
        var root: String?
        if let override = environment["SWIFTLENS_TOOLCHAIN"], !override.isEmpty {
            root = override
        }
        #if os(macOS)
        if root == nil, let swiftc = run("/usr/bin/xcrun", ["--find", "swiftc"]) {
            root = URL(fileURLWithPath: swiftc).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
        #endif
        if root == nil, let swiftc = which("swiftc", environment: environment) {
            let resolved = URL(fileURLWithPath: swiftc).resolvingSymlinksInPath()
            root = resolved.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        }
        guard let root else { return nil }
        return Toolchain(root: root)
    }

    public init(root: String) {
        let fm = FileManager.default
        self.root = root
        let bin = root + "/usr/bin"
        swiftPath = fm.isExecutableFile(atPath: bin + "/swift") ? bin + "/swift" : nil
        swiftcPath = fm.isExecutableFile(atPath: bin + "/swiftc") ? bin + "/swiftc" : nil
        pluginServerPath = fm.isExecutableFile(atPath: bin + "/swift-plugin-server") ? bin + "/swift-plugin-server" : nil

        var plugins = [root + "/usr/lib/swift/host/plugins", root + "/usr/local/lib/swift/host/plugins"]
        var interfaces: [String] = []
        #if os(macOS)
        interfaces.append(root + "/usr/lib/swift/macosx")
        let sdk = Self.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
        sdkPath = sdk
        if let sdk {
            plugins.append(sdk + "/usr/lib/swift/host/plugins")
            interfaces.append(sdk + "/usr/lib/swift")
            interfaces.append(sdk + "/System/Library/Frameworks")
        }
        if let platform = Self.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"]) {
            plugins.append(platform + "/Developer/usr/lib/swift/host/plugins")
            interfaces.append(platform + "/Developer/Library/Frameworks")
        }
        // Xcode's developer dir hosts the SwiftUI / Previews / SwiftData plugins.
        let developer = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().path
        plugins.append(developer + "/usr/lib/swift/host/plugins")
        #else
        sdkPath = nil
        interfaces.append(root + "/usr/lib/swift/linux")
        #endif
        pluginDirectories = plugins.filter { fm.fileExists(atPath: $0) }
        interfaceDirectories = interfaces.filter { fm.fileExists(atPath: $0) }
    }

    /// Library plugins available in the toolchain/SDK, keyed by module name (`ObservationMacros`).
    public func libraryPlugins() -> [String: String] {
        var result: [String: String] = [:]
        for directory in pluginDirectories {
            for (module, path) in Self.libraryPlugins(in: directory) where result[module] == nil {
                result[module] = path
            }
        }
        return result
    }

    public static func libraryPlugins(in directory: String) -> [String: String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var result: [String: String] = [:]
        for entry in entries where entry.hasPrefix("lib") && (entry.hasSuffix(".dylib") || entry.hasSuffix(".so")) {
            let module = String(entry.dropFirst(3).prefix(while: { $0 != "." }))
            result[module] = directory + "/" + entry
        }
        return result
    }

    /// Interface files for the given modules.
    public func interfaceFiles(for modules: [String] = Toolchain.macroDeclaringModules) -> [(module: String, path: String)] {
        let fm = FileManager.default
        var result: [(String, String)] = []
        for module in modules {
            var found = false
            for directory in interfaceDirectories where !found {
                let candidates = [
                    "\(directory)/\(module).swiftmodule",
                    "\(directory)/\(module).framework/Modules/\(module).swiftmodule",
                ]
                for candidate in candidates where !found {
                    guard let files = try? fm.contentsOfDirectory(atPath: candidate) else { continue }
                    let interfaces = files.filter { $0.hasSuffix(".swiftinterface") && !$0.contains(".private.") && !$0.contains(".package.") }
                    if let best = Self.preferredInterface(interfaces) {
                        result.append((module, candidate + "/" + best))
                        found = true
                    }
                }
            }
        }
        return result
    }

    static func preferredInterface(_ files: [String]) -> String? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return files.first { $0.hasPrefix(arch + "e-") } ?? files.first { $0.hasPrefix(arch + "-") } ?? files.sorted().first
    }

    static func which(_ tool: String, environment: [String: String]) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
