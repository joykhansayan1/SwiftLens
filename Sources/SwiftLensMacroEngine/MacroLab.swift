import Foundation
import SwiftLensCore
import SwiftParser
import SwiftSyntax

/// A macro implementation type found in Macro Lab source.
public struct LabMacroType: Codable, Hashable, Sendable {
    public var typeName: String
    public var roles: [MacroDefinition.Role]
    /// The name SwiftLens declares the macro under when the source has no explicit `macro` declaration:
    /// `StringifyMacro` → `#stringify`, `MemberwiseInitMacro` → `@MemberwiseInit`.
    public var suggestedName: String
}

public struct MacroLabBuild: Sendable {
    public var executablePath: String
    public var log: String
    public var diagnostics: [LensDiagnostic]
    public var durationMilliseconds: Double
    public var succeeded: Bool
}

/// Macro Lab: write a macro implementation and its usage side by side, and see the expansion — without creating
/// a package, a macro target, tests or an Xcode project.
///
/// SwiftLens generates a throw-away SwiftPM package around the implementation (adding the `CompilerPlugin`
/// entry point automatically), builds it incrementally and drives the resulting plugin with the regular
/// ``MacroExpander``. The first build compiles swift-syntax; later builds take seconds.
public struct MacroLab: Sendable {
    public var workspace: URL
    public var swiftPath: String
    /// SwiftPM requirement for swift-syntax, e.g. `from: "602.0.0"`, or a local `path:`.
    public var swiftSyntaxDependency: String
    public static let pluginModule = "LabMacros"

    public init(workspace: URL = MacroLab.defaultWorkspace, swiftPath: String, swiftSyntaxDependency: String? = nil) {
        self.workspace = workspace
        self.swiftPath = swiftPath
        if let swiftSyntaxDependency {
            self.swiftSyntaxDependency = swiftSyntaxDependency
        } else if let local = ProcessInfo.processInfo.environment["SWIFTLENS_LAB_SWIFT_SYNTAX_PATH"] {
            self.swiftSyntaxDependency = ".package(path: \"\(local)\")"
        } else {
            self.swiftSyntaxDependency = ".package(url: \"https://github.com/swiftlang/swift-syntax.git\", from: \"602.0.0\")"
        }
    }

    public static var defaultWorkspace: URL {
        MacroRegistry.cacheDirectory.appendingPathComponent("MacroLab/default", isDirectory: true)
    }

    static let roleProtocols: [String: MacroDefinition.Role] = [
        "ExpressionMacro": .expression, "DeclarationMacro": .declaration, "CodeItemMacro": .codeItem,
        "PeerMacro": .peer, "MemberMacro": .member, "AccessorMacro": .accessor,
        "MemberAttributeMacro": .memberAttribute, "ExtensionMacro": .extension, "BodyMacro": .body,
        "PreambleMacro": .preamble,
    ]

    /// Finds macro implementation types by their protocol conformances.
    public static func discoverMacroTypes(in implementation: String) -> [LabMacroType] {
        final class Finder: SyntaxVisitor {
            var types: [LabMacroType] = []
            func record(_ name: String, _ inheritance: InheritanceClauseSyntax?) {
                let roles = (inheritance?.inheritedTypes ?? []).compactMap { MacroLab.roleProtocols[$0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""] }
                guard !roles.isEmpty else { return }
                var base = name.hasSuffix("Macro") ? String(name.dropLast(5)) : name
                if roles.allSatisfy(\.isFreestanding), let first = base.first {
                    base = first.lowercased() + base.dropFirst()
                }
                types.append(LabMacroType(typeName: name, roles: roles, suggestedName: base))
            }
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.inheritanceClause); return .skipChildren }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.inheritanceClause); return .skipChildren }
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { record(node.name.text, node.inheritanceClause); return .skipChildren }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(Parser.parse(source: implementation))
        return finder.types
    }

    /// Declarations for discovered macro types, used when the usage source does not declare them itself.
    public static func synthesizedDeclarations(for types: [LabMacroType]) -> String {
        types.map { type in
            let attributes = type.roles.map { role -> String in
                switch role {
                case .expression, .declaration, .codeItem:
                    return "@freestanding(\(role.rawValue)\(role == .declaration ? ", names: arbitrary" : ""))"
                case .extension, .conformance:
                    return "@attached(extension, names: arbitrary)"
                case .peer, .member:
                    return "@attached(\(role.rawValue), names: arbitrary)"
                case .accessor, .memberAttribute, .body, .preamble:
                    return "@attached(\(role.rawValue))"
                }
            }.joined(separator: " ")
            let signature = type.roles.contains(.expression) ? "(_ arguments: Any...) -> Any" : "(_ arguments: Any...)"
            return "\(attributes) macro \(type.suggestedName)\(signature) = #externalMacro(module: \"\(pluginModule)\", type: \"\(type.typeName)\")"
        }.joined(separator: "\n")
    }

    /// Writes the package (only touching files whose content changed, to keep builds incremental).
    public func prepare(implementation: String) throws -> [LabMacroType] {
        let types = Self.discoverMacroTypes(in: implementation)
        let fm = FileManager.default
        let sources = workspace.appendingPathComponent("Sources/\(Self.pluginModule)", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)

        let manifest = """
        // swift-tools-version: 5.9
        // Generated by SwiftLens Macro Lab.
        import PackageDescription

        let package = Package(
            name: "SwiftLensMacroLab",
            platforms: [.macOS(.v13)],
            dependencies: [
                \(swiftSyntaxDependency),
            ],
            targets: [
                .executableTarget(
                    name: "\(Self.pluginModule)",
                    dependencies: [
                        .product(name: "SwiftSyntax", package: "swift-syntax"),
                        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                    ]
                ),
            ]
        )

        """
        let hasEntryPoint = implementation.contains("CompilerPlugin") && implementation.contains("@main")
        var entry = """
        // Generated by SwiftLens Macro Lab.
        import SwiftCompilerPlugin
        import SwiftSyntaxMacros

        """
        if !hasEntryPoint {
            entry += """
            @main
            struct SwiftLensLabPlugin: CompilerPlugin {
                let providingMacros: [Macro.Type] = [\(types.map { "\($0.typeName).self" }.joined(separator: ", "))]
            }

            """
        }
        try writeIfChanged(manifest, to: workspace.appendingPathComponent("Package.swift"))
        try writeIfChanged(implementation, to: sources.appendingPathComponent("Implementation.swift"))
        try writeIfChanged(entry, to: sources.appendingPathComponent("SwiftLensLabPlugin.swift"))
        return types
    }

    private func writeIfChanged(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Builds the plugin executable.
    public func build(timeout: Double = 900) -> MacroLabBuild {
        let started = DispatchTime.now()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = ["build", "--package-path", workspace.path, "--product", Self.pluginModule]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var log = ""
        do {
            try process.run()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            log = String(decoding: data, as: UTF8.self)
        } catch {
            log = "Could not run \(swiftPath): \(error)"
        }
        let executable = workspace.appendingPathComponent(".build/debug/\(Self.pluginModule)").path
        let implementationPath = workspace.appendingPathComponent("Sources/\(Self.pluginModule)/Implementation.swift").path
        let diagnostics = log.split(separator: "\n").compactMap { line -> LensDiagnostic? in
            let text = String(line)
            guard text.hasPrefix(implementationPath + ":") else { return nil }
            let rest = text.dropFirst(implementationPath.count + 1)
            let parts = rest.split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let lineNumber = Int(parts[0]), let column = Int(parts[1]) else { return nil }
            let severity = LensSeverity(rawValue: parts[2].trimmingCharacters(in: .whitespaces)) ?? .error
            return LensDiagnostic(severity: severity, message: parts[3].trimmingCharacters(in: .whitespaces), position: SourcePosition(line: lineNumber, column: column, offset: 0), origin: .compiler)
        }
        let succeeded = process.terminationReason == .exit && process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: executable)
        return MacroLabBuild(
            executablePath: executable,
            log: log,
            diagnostics: diagnostics,
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000,
            succeeded: succeeded
        )
    }

    /// Prepares, builds and expands `usage` with the lab plugin. Explicit `macro` declarations in `usage`
    /// or `declarations` win over the synthesized ones.
    public func run(implementation: String, usage: String, declarations: String = "", fileName: String = "Usage.swift") -> (MacroLabBuild, ExpansionReport?) {
        let types: [LabMacroType]
        do {
            types = try prepare(implementation: implementation)
        } catch {
            return (MacroLabBuild(executablePath: "", log: "\(error)", diagnostics: [], durationMilliseconds: 0, succeeded: false), nil)
        }
        let build = build()
        guard build.succeeded else { return (build, nil) }

        let registry = MacroRegistry(MacroDeclarationScanner.scan(source: Self.synthesizedDeclarations(for: types), origin: "Macro Lab"))
        registry.addDeclarations(source: declarations, origin: "Macro Lab declarations")
        var configuration = MacroPluginHost.Configuration()
        configuration.executablePlugins = [ExecutablePlugin(path: build.executablePath, modules: [Self.pluginModule])]
        configuration.useToolchainPlugins = true
        let host = MacroPluginHost(configuration: configuration, toolchain: Toolchain.detect())
        defer { host.shutdown() }
        let report = MacroExpander(registry: registry, host: host).expand(source: usage, fileName: fileName)
        return (build, report)
    }
}
