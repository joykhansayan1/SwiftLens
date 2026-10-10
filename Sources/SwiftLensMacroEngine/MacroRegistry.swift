import Foundation
import SwiftLensCore

/// All macro declarations SwiftLens knows about, keyed by macro name.
public final class MacroRegistry: @unchecked Sendable {
    public private(set) var definitionsByName: [String: [MacroDefinition]] = [:]
    private let lock = NSLock()

    public init(_ definitions: [MacroDefinition] = []) {
        add(definitions)
    }

    public var allDefinitions: [MacroDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitionsByName.values.flatMap { $0 }.sorted { ($0.name, $0.moduleName) < ($1.name, $1.moduleName) }
    }

    public var count: Int { allDefinitions.count }

    public func add(_ definitions: [MacroDefinition]) {
        lock.lock()
        defer { lock.unlock() }
        for definition in definitions {
            var list = definitionsByName[definition.name, default: []]
            if !list.contains(where: { $0.declaration == definition.declaration && $0.moduleName == definition.moduleName }) {
                // User-provided declarations (added later) take precedence over toolchain ones.
                list.insert(definition, at: 0)
            }
            definitionsByName[definition.name] = list
        }
    }

    /// Adds declarations from Swift sources / interfaces. Directories are searched recursively
    /// (skipping `.build`, `DerivedData` and hidden folders).
    public func addDeclarations(fromPaths paths: [String]) {
        var definitions: [MacroDefinition] = []
        for path in paths {
            for file in Self.swiftFiles(at: path) {
                definitions += MacroDeclarationScanner.scan(fileAt: file)
            }
        }
        add(definitions)
    }

    public func addDeclarations(source: String, origin: String = "<inline>") {
        add(MacroDeclarationScanner.scan(source: source, origin: origin))
    }

    /// Adds the macros declared by the toolchain and SDK (Observation, SwiftUI, Foundation, Testing, ...).
    /// Results are cached on disk keyed by the interface files' paths and modification dates.
    public func addToolchainMacros(_ toolchain: Toolchain, useCache: Bool = true) {
        let files = toolchain.interfaceFiles()
        let fm = FileManager.default
        let fingerprint = files.map { file -> String in
            let date = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(file.path)@\(date)"
        }.joined(separator: "|")
        let cacheFile = Self.cacheDirectory.appendingPathComponent("toolchain-macros-\(Self.stableHash(fingerprint)).json")

        if useCache, let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode([MacroDefinition].self, from: data) {
            add(cached)
            return
        }
        var definitions: [MacroDefinition] = []
        for file in files {
            definitions += MacroDeclarationScanner.scan(fileAt: file.path, declaringModule: file.module)
        }
        // Lower precedence than user declarations: append rather than insert.
        lock.lock()
        for definition in definitions {
            var list = definitionsByName[definition.name, default: []]
            if !list.contains(where: { $0.declaration == definition.declaration }) { list.append(definition) }
            definitionsByName[definition.name] = list
        }
        lock.unlock()
        if useCache {
            try? fm.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(definitions) { try? data.write(to: cacheFile) }
        }
    }

    /// Picks the best declaration for a use site, using argument labels to disambiguate overloads.
    public func resolve(_ usage: MacroUsage) -> MacroDefinition? {
        resolve(name: usage.name, attached: usage.kind == .attached, labels: usage.argumentLabels, hasTrailingClosure: usage.hasTrailingClosure)
    }

    public func resolve(name: String, attached: Bool, labels: [String?] = [], hasTrailingClosure: Bool = false) -> MacroDefinition? {
        lock.lock()
        let candidates = (definitionsByName[name] ?? []).filter { $0.isFreestanding != attached }
        lock.unlock()
        guard candidates.count > 1 else { return candidates.first }
        return candidates.max { score($0, labels, hasTrailingClosure) < score($1, labels, hasTrailingClosure) }
    }

    public func definitions(named name: String) -> [MacroDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitionsByName[name] ?? []
    }

    private func score(_ definition: MacroDefinition, _ labels: [String?], _ trailingClosure: Bool) -> Int {
        var parameterLabels = definition.parameterLabels
        if trailingClosure && definition.acceptsTrailingClosure && !parameterLabels.isEmpty { parameterLabels.removeLast() }
        var score = 0
        var index = 0
        var matched = 0
        for label in labels {
            if index < parameterLabels.count, let position = parameterLabels[index...].firstIndex(where: { $0 == label }) {
                score += 10
                matched += 1
                index = position + 1
            } else {
                score -= 10
            }
        }
        // Prefer the overload with the fewest parameters left unspecified.
        score -= (parameterLabels.count - matched)
        if trailingClosure && definition.acceptsTrailingClosure { score += 5 }
        // Prefer SwiftUI flavours of overloaded preview macros.
        if definition.typeName.contains("SwiftUI") { score += 1 }
        return score
    }

    static var cacheDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? (NSHomeDirectory() + "/.cache"))
        #endif
        return base.appendingPathComponent("SwiftLens", isDirectory: true)
    }

    static func stableHash(_ string: String) -> String {
        // FNV-1a 64-bit; stable across launches (unlike `Hasher`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    static func swiftFiles(at path: String) -> [String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [path] }
        guard let enumerator = fm.enumerator(atPath: path) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") || name == "DerivedData" || name == ".build" || name == "Pods" || name == "Carthage" {
                enumerator.skipDescendants()
                continue
            }
            if name.hasSuffix(".swift") || name.hasSuffix(".swiftinterface") {
                files.append(path + "/" + relative)
            }
        }
        return files
    }
}
