import Foundation

/// An executable macro plugin, as passed to the compiler with `-load-plugin-executable <path>#<modules>`.
public struct ExecutablePlugin: Codable, Hashable, Sendable {
    public var path: String
    /// Modules this executable provides. Empty means "any module" (used as a fallback).
    public var modules: [String]

    public init(path: String, modules: [String] = []) {
        self.path = path
        self.modules = modules
    }

    /// Parses the compiler's `path#Module1,Module2` syntax.
    public init(argument: String) {
        let parts = argument.split(separator: "#", maxSplits: 1)
        path = String(parts[0])
        modules = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
    }
}

public enum MacroPluginHostError: Error, CustomStringConvertible {
    case noPluginForModule(String, searched: [String])
    case noPluginServer(module: String, library: String)

    public var description: String {
        switch self {
        case .noPluginForModule(let module, let searched):
            "No macro plugin provides module '\(module)'." +
                (searched.isEmpty ? "" : " Searched: \(searched.joined(separator: ", ")).") +
                " Pass --plugin <executable>#\(module), or --plugin-path <dir> (e.g. .build/debug)."
        case .noPluginServer(let module, let library):
            "Found library plugin \(library) for '\(module)', but no swift-plugin-server to host it."
        }
    }
}

/// Resolves plugin modules to running plugin processes and keeps them alive between expansions,
/// so live re-expansion while typing costs a single IPC round-trip per macro.
public final class MacroPluginHost: @unchecked Sendable {
    public struct Configuration: Codable, Sendable {
        public var executablePlugins: [ExecutablePlugin] = []
        /// Explicit library plugins: module name → `lib*.dylib/.so` path.
        public var libraryPlugins: [String: String] = [:]
        /// Directories searched for library plugins and for SwiftPM/Xcode-built plugin executables
        /// (`<Module>-tool` or `<Module>`).
        public var pluginSearchPaths: [String] = []
        public var pluginServerPath: String?
        public var useToolchainPlugins: Bool = true
        public var timeout: Double = 20

        public init() {}
    }

    public let configuration: Configuration
    public let toolchain: Toolchain?
    private var executableConnections: [String: PluginConnection] = [:]
    private var serverConnection: PluginConnection?
    private let lock = NSLock()

    public init(configuration: Configuration = .init(), toolchain: Toolchain? = Toolchain.detect()) {
        self.configuration = configuration
        self.toolchain = toolchain
    }

    deinit {
        shutdown()
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        executableConnections.values.forEach { $0.shutdown() }
        executableConnections.removeAll()
        serverConnection?.shutdown()
        serverConnection = nil
    }

    /// Describes where a module's implementation would come from, without launching anything.
    public func describeProvider(for module: String) -> String? {
        if let plugin = executablePlugin(for: module) { return plugin }
        if let library = libraryPath(for: module) { return library }
        return nil
    }

    /// Returns a live connection able to expand macros implemented in `module`.
    public func connection(for module: String) throws -> PluginConnection {
        lock.lock()
        defer { lock.unlock() }

        if let executable = executablePlugin(for: module) {
            if let existing = executableConnections[executable], existing.isRunning { return existing }
            let connection = try PluginConnection(executablePath: executable, timeout: configuration.timeout)
            executableConnections[executable] = connection
            return connection
        }
        if let library = libraryPath(for: module) {
            guard let serverPath = configuration.pluginServerPath ?? toolchain?.pluginServerPath else {
                throw MacroPluginHostError.noPluginServer(module: module, library: library)
            }
            if serverConnection == nil || serverConnection?.isRunning == false {
                serverConnection = try PluginConnection(executablePath: serverPath, timeout: configuration.timeout)
            }
            try serverConnection!.loadLibrary(path: library, moduleName: module)
            return serverConnection!
        }
        throw MacroPluginHostError.noPluginForModule(module, searched: configuration.pluginSearchPaths + (toolchain?.pluginDirectories ?? []))
    }

    private func executablePlugin(for module: String) -> String? {
        if let explicit = configuration.executablePlugins.first(where: { $0.modules.contains(module) }) {
            return explicit.path
        }
        let fm = FileManager.default
        for directory in configuration.pluginSearchPaths {
            for candidate in ["\(directory)/\(module)-tool", "\(directory)/\(module)"] {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
                   fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        // A wildcard executable (no modules listed) is the last resort for executables.
        if libraryPath(for: module) == nil, let wildcard = configuration.executablePlugins.first(where: { $0.modules.isEmpty }) {
            return wildcard.path
        }
        return nil
    }

    private func libraryPath(for module: String) -> String? {
        if let explicit = configuration.libraryPlugins[module] { return explicit }
        for directory in configuration.pluginSearchPaths {
            if let path = Toolchain.libraryPlugins(in: directory)[module] { return path }
        }
        if configuration.useToolchainPlugins, let path = toolchain?.libraryPlugins()[module] { return path }
        return nil
    }
}
