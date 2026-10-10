import ArgumentParser
import Foundation
import SwiftLensCore
import SwiftLensMacroEngine
import SwiftLensRenderer
import SwiftLensSandbox

struct SwiftLensCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftlens",
        abstract: "Local-first Swift macro visualizer and SwiftUI render sandbox.",
        discussion: """
        Everything runs on your machine: macros are expanded by talking to the real macro plugins (no project build),
        and SwiftUI previews are compiled and rendered in an isolated process.
        """,
        version: SwiftLensVersion.current,
        subcommands: [Expand.self, Macros.self, Tree.self, Previews.self, Render.self, Live.self, Lab.self, MigratePreviews.self, Doctor.self]
    )
}

enum SwiftLensVersion {
    static let current = "0.1.0"
}

struct PluginOptions: ParsableArguments {
    @Option(name: .customLong("plugin"), help: ArgumentHelp("Executable macro plugin, as for the compiler: <path>#<Module>[,<Module>].", valueName: "path#module"))
    var plugins: [String] = []

    @Option(name: .customLong("plugin-path"), help: ArgumentHelp("Directory with library plugins (lib*.dylib/.so) or built plugin executables (e.g. .build/debug).", valueName: "dir"))
    var pluginPaths: [String] = []

    @Option(name: .customLong("decls"), help: ArgumentHelp("Swift file or directory containing `macro` declarations (e.g. your macro library's sources).", valueName: "path"))
    var declarationPaths: [String] = []

    @Flag(name: .customLong("no-toolchain"), help: "Do not load the toolchain/SDK macros (@Observable, #Preview, #Predicate, @Test, ...).")
    var noToolchain = false

    @Option(help: "Seconds to wait for a plugin response.")
    var timeout: Double = 20

    func makeExpander() -> MacroExpander {
        let toolchain = Toolchain.detect()
        let registry = MacroRegistry()
        if !noToolchain, let toolchain { registry.addToolchainMacros(toolchain) }
        registry.addDeclarations(fromPaths: declarationPaths)
        var configuration = MacroPluginHost.Configuration()
        configuration.executablePlugins = plugins.map(ExecutablePlugin.init(argument:))
        configuration.pluginSearchPaths = pluginPaths
        configuration.useToolchainPlugins = !noToolchain
        configuration.timeout = timeout
        return MacroExpander(registry: registry, host: MacroPluginHost(configuration: configuration, toolchain: toolchain))
    }
}

// MARK: - expand

struct Expand: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Expand every macro in a file and print the fully expanded source, a diff, or each expansion.",
        discussion: """
        Examples:
          swiftlens expand Model.swift                       # @Observable, #Preview, #Predicate... work out of the box
          swiftlens expand Usage.swift --plugin .build/debug/MyMacros#MyMacros --decls Sources/MyLib
          swiftlens expand Usage.swift --plugin-path .build/debug --decls Sources/MyLib --format diff
          swiftlens expand Model.swift --verify              # cross-check against swiftc -dump-macro-expansions
        """
    )

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case full, diff, expansions, json
    }

    @Argument(help: "Swift file to expand (`-` for stdin).")
    var file: String

    @OptionGroup var pluginOptions: PluginOptions

    @Option(name: .shortAndLong, help: "Output format: full | diff | expansions | json.")
    var format: Format = .full

    @Option(help: "Module name reported to macros.")
    var moduleName = "SwiftLensSnippet"

    @Flag(help: "Keep compiler-mangled unique names ($s…fMu_) instead of readable ones.")
    var rawNames = false

    @Flag(help: "Also expand with swiftc -dump-macro-expansions and report differences.")
    var verify = false

    @Option(name: .customLong("Xswiftc"), parsing: .unconditionalSingleValue, help: "Extra argument passed to swiftc when using --verify.")
    var swiftcArguments: [String] = []

    @Option(name: .shortAndLong, help: "Write the expanded source to this file.")
    var output: String?

    func run() throws {
        let (source, name) = try readSource(file)
        let expander = pluginOptions.makeExpander()
        defer { expander.host.shutdown() }
        let report = expander.expand(
            SourceDocument(text: source, fileName: name),
            options: MacroExpansionOptions(moduleName: moduleName, readableUniqueNames: !rawNames)
        )

        switch format {
        case .json:
            print(try Terminal.json(report))
        case .full:
            print(report.expandedSource, terminator: report.expandedSource.hasSuffix("\n") ? "" : "\n")
        case .diff:
            let diff = report.unifiedDiff
            print(diff.isEmpty ? Terminal.dim("(no macros expanded)") : Terminal.colorizedDiff(diff), terminator: diff.hasSuffix("\n") ? "" : "\n")
        case .expansions:
            for record in report.expansions {
                let location = record.position.map { "\(name):\($0.line):\($0.column)" } ?? Terminal.dim("(inside generated code)")
                let target = record.attachedTo.map { " on \($0)" } ?? ""
                print(Terminal.bold("\(record.spelling)") + Terminal.dim(" \(record.role.rawValue)\(target) — \(record.moduleName).\(record.typeName) — \(String(format: "%.1f", record.durationMilliseconds)) ms"))
                print(Terminal.dim("  at ") + location)
                for line in record.expandedSource.split(separator: "\n", omittingEmptySubsequences: false) {
                    print(Terminal.green("  │ ") + line)
                }
                print("")
            }
        }

        if let output {
            try report.expandedSource.write(toFile: output, atomically: true, encoding: .utf8)
        }

        if format != .json {
            for diagnostic in report.diagnostics {
                Terminal.printDiagnostic(diagnostic, fileName: name)
            }
            for usage in report.unresolvedMacros {
                FileHandle.standardError.write(Data((Terminal.yellow("unresolved: ") + "\(usage.spelling) at \(name):\(usage.span.start) — pass --decls with its declaration\n").utf8))
            }
            FileHandle.standardError.write(Data(Terminal.dim("\(report.expansions.count) expansion(s) in \(String(format: "%.1f", report.durationMilliseconds)) ms\n").utf8))
        }

        if verify {
            guard let toolchain = Toolchain.detect() else { throw ValidationError("--verify needs a Swift toolchain") }
            let path: String
            if file == "-" {
                path = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlens-verify-\(UUID().uuidString).swift").path
                try source.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                path = file
            }
            var arguments = swiftcArguments
            for plugin in pluginOptions.plugins { arguments += ["-load-plugin-executable", plugin] }
            for directory in pluginOptions.pluginPaths { arguments += ["-plugin-path", directory] }
            let compiler = try CompilerExpansionDump.run(files: [path], toolchain: toolchain, extraArguments: arguments)
            let problems = CompilerExpansionDump.verify(report: report, against: compiler.expansions)
            if problems.isEmpty {
                FileHandle.standardError.write(Data((Terminal.green("✓ verified: ") + "\(compiler.expansions.count) compiler expansion(s) match\n").utf8))
            } else {
                for problem in problems { FileHandle.standardError.write(Data((Terminal.yellow("≠ ") + problem + "\n").utf8)) }
                if !compiler.diagnostics.isEmpty { FileHandle.standardError.write(Data((Terminal.dim(compiler.diagnostics) + "\n").utf8)) }
                throw ExitCode(2)
            }
        }
        if report.hasErrors { throw ExitCode(1) }
    }
}

// MARK: - macros

struct Macros: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List macro uses in a file and which plugin implements each one.")

    @Argument(help: "Swift file (`-` for stdin).")
    var file: String

    @OptionGroup var pluginOptions: PluginOptions

    @Flag(help: "Print JSON.")
    var json = false

    @Flag(help: "List every macro declaration SwiftLens knows about instead.")
    var all = false

    func run() throws {
        let expander = pluginOptions.makeExpander()
        defer { expander.host.shutdown() }
        if all {
            let definitions = expander.registry.allDefinitions
            if json { print(try Terminal.json(definitions)); return }
            for definition in definitions {
                let provider = expander.host.describeProvider(for: definition.moduleName) ?? Terminal.yellow("no plugin found")
                print("\(Terminal.bold(definition.isFreestanding ? "#" + definition.name : "@" + definition.name)) \(Terminal.dim(definition.roles.map(\.rawValue).joined(separator: ",")))  \(definition.moduleName).\(definition.typeName)  \(Terminal.dim(provider))")
            }
            return
        }
        let (source, name) = try readSource(file)
        let document = SourceDocument(text: source, fileName: name)
        expander.registry.addDeclarations(source: source, origin: name)
        let usages = MacroUsageScanner.scan(document)

        struct Row: Encodable {
            var usage: MacroUsage
            var definition: MacroDefinition?
            var provider: String?
        }
        let rows = usages.map { usage -> Row in
            let definition = expander.registry.resolve(usage)
            return Row(usage: usage, definition: definition, provider: definition.flatMap { expander.host.describeProvider(for: $0.moduleName) })
        }
        if json { print(try Terminal.json(rows)); return }
        for row in rows {
            let location = "\(name):\(row.usage.span.start)"
            if let definition = row.definition {
                print("\(Terminal.bold(row.usage.spelling)) \(Terminal.dim(location))  → \(definition.moduleName).\(definition.typeName) \(Terminal.dim("[" + definition.roles.map(\.rawValue).joined(separator: ", ") + "]"))  \(Terminal.dim(row.provider ?? "no plugin found"))")
            } else if MacroUsageScanner.wellKnownNonMacroAttributes.contains(row.usage.name) {
                continue
            } else {
                print("\(Terminal.yellow(row.usage.spelling)) \(Terminal.dim(location))  → no declaration found (property wrapper, result builder, or pass --decls)")
            }
        }
    }
}

// MARK: - tree

struct Tree: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the swift-syntax tree of a file, with ready-to-paste access paths for macro authors.",
        discussion: """
        Examples:
          swiftlens tree Model.swift --depth 4
          swiftlens tree Model.swift --at 12:9 --paths      # the node under the cursor and how to reach it
          echo 'let x = 1' | swiftlens tree - --json
        """
    )

    @Argument(help: "Swift file (`-` for stdin).")
    var file: String

    @Flag(help: "Print JSON.")
    var json = false

    @Flag(name: .customLong("no-tokens"), help: "Hide token leaves.")
    var noTokens = false

    @Flag(help: "Show the Swift access path of every node.")
    var paths = false

    @Flag(name: .customLong("no-spans"), help: "Hide line:column ranges.")
    var noSpans = false

    @Option(help: "Maximum depth.")
    var depth: Int?

    @Option(help: "Show the chain of nodes at a position, as line:column.")
    var at: String?

    func run() throws {
        let (source, name) = try readSource(file)
        let document = SourceDocument(text: source, fileName: name)
        let tree = SyntaxTreeBuilder.build(document, options: .init(includeTokens: !noTokens, maxDepth: depth))

        if let at {
            let parts = at.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { throw ValidationError("--at expects line:column") }
            let offset = document.converter.position(ofLine: parts[0], column: parts[1]).utf8Offset
            let chain = tree.path(toOffset: offset)
            if json { print(try Terminal.json(chain.map { node -> SyntaxTreeNode in var copy = node; copy.children = []; return copy })); return }
            for (level, node) in chain.enumerated() {
                let label = node.token.map { "\($0.kind) \($0.text.debugDescription)" } ?? node.kind + (node.summary.map { " ‹\($0)›" } ?? "")
                print(String(repeating: "  ", count: level) + Terminal.bold(label) + Terminal.dim("  \(node.span)"))
            }
            if let innermost = chain.last(where: { $0.token == nil }) ?? chain.last {
                print("\n" + Terminal.cyan("access path: ") + innermost.accessPath)
            }
            return
        }

        if json {
            print(try Terminal.json(tree))
        } else {
            print(tree.asciiTree(showSpans: !noSpans, showAccessPaths: paths))
        }
        for diagnostic in document.parserDiagnostics {
            Terminal.printDiagnostic(diagnostic, fileName: name)
        }
    }
}

// MARK: - previews

struct Previews: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the previews SwiftLens can render in a file.")

    @Argument(help: "Swift file (`-` for stdin).")
    var file: String

    @Flag(help: "Print JSON.")
    var json = false

    @Flag(help: "Print the generated render harness instead.")
    var harness = false

    func run() throws {
        let (source, name) = try readSource(file)
        let document = SourceDocument(text: source, fileName: name)
        if harness {
            let generated = HarnessGenerator.generate(document)
            print(generated.harnessSource)
            return
        }
        let entries = PreviewExtractor.extract(document)
        if json { print(try Terminal.json(entries)); return }
        if entries.isEmpty { print(Terminal.dim("No previews found.")) }
        for entry in entries {
            let traits = entry.traits.isEmpty ? "" : Terminal.dim(" traits: \(entry.traits)")
            let state = entry.previewableDeclarations.isEmpty ? "" : Terminal.dim(" @Previewable: \(entry.previewableDeclarations.joined(separator: "; "))")
            print("\(Terminal.bold("[\(entry.id)]")) \(entry.name) \(Terminal.dim("(\(entry.kind.rawValue), line \(entry.span.start.line))"))\(traits)\(state)")
        }
    }
}

// MARK: - render

struct RenderOptions: ParsableArguments {
    @Option(name: .customLong("appearance"), parsing: .upToNextOption, help: "light and/or dark.")
    var appearances: [String] = ["light"]

    @Option(name: .customLong("dynamic-type"), parsing: .upToNextOption, help: "Dynamic Type sizes, e.g. large accessibility3.")
    var dynamicTypeSizes: [String] = ["large"]

    @Option(name: .customLong("locale"), parsing: .upToNextOption, help: "Locales, e.g. en ar ja.")
    var locales: [String] = []

    @Flag(help: "Also render right-to-left.")
    var rtl = false

    @Option(name: .customLong("device"), parsing: .upToNextOption, help: "Canvas presets: \(DevicePreset.all.map(\.name).joined(separator: ", ")).")
    var devices: [String] = []

    @Option(help: "Fixed canvas size WxH (points).")
    var size: String?

    @Option(help: "Pixel scale.")
    var scale: Double = 2

    @Option(help: "appkit (default, renders platform controls) or image-renderer.")
    var engine: String = "appkit"

    @Option(name: .customLong("Xswiftc"), parsing: .unconditionalSingleValue, help: "Extra argument for swiftc (e.g. -F/-I/-L for your frameworks).")
    var swiftcArguments: [String] = []

    @Option(help: "Seconds before a single render is considered hung.")
    var renderTimeout: Double = 15

    func variants() throws -> [RenderVariant] {
        for size in dynamicTypeSizes where !RenderVariant.validDynamicTypeSizes.contains(size) {
            throw ValidationError("Unknown Dynamic Type size '\(size)'. Valid: \(RenderVariant.validDynamicTypeSizes.joined(separator: ", "))")
        }
        var presets: [DevicePreset?] = try devices.map { name in
            guard let preset = DevicePreset.named(name) else { throw ValidationError("Unknown device '\(name)'") }
            return preset
        }
        if let size {
            let parts = size.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { throw ValidationError("--size expects WxH, e.g. 390x844") }
            presets.append(DevicePreset(name: "\(Int(parts[0]))x\(Int(parts[1]))", width: parts[0], height: parts[1]))
        }
        return RenderVariant.matrix(
            colorSchemes: appearances,
            dynamicTypeSizes: dynamicTypeSizes,
            locales: locales.isEmpty ? [nil] : locales.map { Optional($0) },
            layoutDirections: rtl ? ["leftToRight", "rightToLeft"] : ["leftToRight"],
            devices: presets.isEmpty ? [nil] : presets,
            engine: engine == "image-renderer" ? .imageRenderer : .appKit,
            scale: scale
        )
    }

    func compiler() -> SnippetCompiler {
        let toolchain = Toolchain.detect()
        return SnippetCompiler(options: .init(swiftcPath: toolchain?.swiftcPath, sdkPath: toolchain?.sdkPath, extraArguments: swiftcArguments))
    }
}

func selectPreviews(_ selectors: [String], in entries: [PreviewEntry]) throws -> [Int] {
    try selectors.map { selector in
        if let index = Int(selector), entries.indices.contains(index) { return index }
        if let entry = entries.first(where: { $0.name == selector }) { return entry.id }
        throw ValidationError("No preview '\(selector)'. Available: \(entries.map { "[\($0.id)] \($0.name)" }.joined(separator: ", "))")
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render SwiftUI previews to PNG — no Xcode project needed (macOS).",
        discussion: """
        Examples:
          swiftlens render Card.swift
          swiftlens render Card.swift --appearance light dark --dynamic-type large accessibility3 --out shots/
          swiftlens render Card.swift --device "iPhone 16" --locale en ar --rtl --preview Card
        """
    )

    @Argument(help: "Swift file (`-` for stdin).")
    var file: String

    @Option(name: .customLong("preview"), parsing: .upToNextOption, help: "Preview index or name (default: all).")
    var previews: [String] = []

    @Option(name: .shortAndLong, help: "Output directory for PNGs.")
    var out: String = "swiftlens-renders"

    @OptionGroup var renderOptions: RenderOptions

    @Flag(help: "Print JSON.")
    var json = false

    @Flag(help: "Print the swiftc command line and generated harness without compiling.")
    var dryRun = false

    func run() throws {
        let (source, name) = try readSource(file)
        let document = SourceDocument(text: source, fileName: name)
        let entries = PreviewExtractor.extract(document)
        let indices = try selectPreviews(previews, in: entries)
        let variants = try renderOptions.variants()
        let compiler = renderOptions.compiler()

        if dryRun {
            print(compiler.commandLine(sources: ["Snippet.swift", "SwiftLensHarness.swift"], output: "libSwiftLensSnippet.dylib", moduleName: "SwiftLensSnippet").joined(separator: " "))
            print(HarnessGenerator.generate(document).harnessSource)
            return
        }

        #if !os(macOS)
        throw ValidationError("Rendering SwiftUI requires macOS. Use --dry-run to inspect the generated harness.")
        #else
        let pipeline = RenderPipeline(compiler: compiler)
        let outputDirectory = URL(fileURLWithPath: out).standardizedFileURL.path
        let (report, _) = pipeline.render(document, variants: variants, previewIndices: indices, outputDirectory: outputDirectory, timeout: renderOptions.renderTimeout)
        if json {
            print(try Terminal.json(report))
        } else {
            for diagnostic in report.compileDiagnostics { Terminal.printDiagnostic(diagnostic, fileName: name) }
            if let failure = report.agentFailure { Terminal.error(failure) }
            for output in report.outputs {
                if let path = output.imagePath {
                    print("\(Terminal.green("✓")) \(output.previewName) \(Terminal.dim("[\(output.variant.label)]")) → \(path) \(Terminal.dim("\(output.pixelWidth)×\(output.pixelHeight)px, \(String(format: "%.0f", output.durationMilliseconds)) ms"))")
                } else {
                    print("\(Terminal.red("✗")) \(output.previewName) \(Terminal.dim("[\(output.variant.label)]")): \(output.error ?? "unknown error")")
                }
            }
            let compileNote = report.cacheHit ? "cached build" : "compiled in \(String(format: "%.0f", report.compileDurationMilliseconds)) ms"
            FileHandle.standardError.write(Data(Terminal.dim("\(compileNote), rendered in \(String(format: "%.0f", report.renderDurationMilliseconds)) ms\n").utf8))
        }
        if report.agentFailure != nil || report.compileDiagnostics.contains(where: { $0.severity == .error }) || report.outputs.contains(where: { $0.error != nil }) {
            throw ExitCode(1)
        }
        #endif
    }
}

// MARK: - live

struct Live: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open an interactive preview window that hot-reloads whenever the file is saved (macOS).",
        discussion: "Works with any editor: save the file and the window reloads in place, keeping its position and size."
    )

    @Argument(help: "Swift file.")
    var file: String

    @Option(help: "Preview index or name.")
    var preview: String?

    @OptionGroup var renderOptions: RenderOptions

    @Option(help: "Polling interval in seconds.")
    var interval: Double = 0.3

    func run() throws {
        #if !os(macOS)
        throw ValidationError("Live previews require macOS.")
        #else
        let compiler = renderOptions.compiler()
        let client = RenderClient()
        let variant = try renderOptions.variants().first ?? RenderVariant(label: "default")
        let frame = FrameBox()
        var process: Process?
        var lastModified: Date?

        func reload() {
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            let document = SourceDocument(text: source, fileName: file)
            let started = Date()
            do {
                let compiled = try compiler.compile(document)
                let entries = compiled.entries
                guard !entries.isEmpty else { Terminal.error("No previews in \(file)"); return }
                let index = try selectPreviews(preview.map { [$0] } ?? [], in: entries).first ?? 0
                process?.terminate()
                let job = LiveWindowJob(libraryPath: compiled.libraryPath, previewIndex: index, variant: variant.applying(entries[index].traits), title: entries[index].name, frame: frame.value)
                process = try client.openLiveWindow(job) { frame.value = $0 }
                print(Terminal.green("↻ ") + "\(entries[index].name) " + Terminal.dim(String(format: "(%.0f ms%@)", Date().timeIntervalSince(started) * 1000, compiled.cacheHit ? ", cached" : "")))
            } catch SnippetCompilerError.compilationFailed(let diagnostics, let log) {
                if diagnostics.isEmpty { Terminal.error(log) }
                for diagnostic in diagnostics { Terminal.printDiagnostic(diagnostic, fileName: file) }
            } catch {
                Terminal.error("\(error)")
            }
        }

        print(Terminal.dim("Watching \(file) — save to reload, Ctrl-C to quit."))
        while true {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]) as? Date
            if modified != lastModified {
                lastModified = modified
                reload()
            }
            if let running = process, !running.isRunning, running.terminationStatus != 0 && running.terminationStatus != 15 {
                Terminal.error("Preview process exited with status \(running.terminationStatus)")
                process = nil
            }
            Thread.sleep(forTimeInterval: interval)
        }
        #endif
    }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double]?
    var value: [Double]? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - lab

struct Lab: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Macro Lab: build a macro implementation on the fly and expand a usage file with it.",
        discussion: """
        No package or macro target needed. Implementation types are discovered by their protocols
        (ExpressionMacro, MemberMacro, ...) and declared as `#name` / `@Name` (type name minus "Macro"),
        unless the usage file or --decls declares them explicitly.

          swiftlens lab MyMacro.swift --usage Example.swift --format diff
        """
    )

    @Argument(help: "Swift file with the macro implementation(s).")
    var implementation: String

    @Option(help: "Swift file using the macro(s).")
    var usage: String

    @Option(name: .customLong("decls"), help: "Optional file with explicit `macro` declarations.")
    var declarations: String?

    @Option(help: "Workspace directory for the generated package (default: cache).")
    var workspace: String?

    @Option(name: .shortAndLong, help: "Output format: full | diff | expansions | json.")
    var format: Expand.Format = .diff

    func run() throws {
        guard let toolchain = Toolchain.detect(), let swift = toolchain.swiftPath else { throw ValidationError("No Swift toolchain found") }
        let lab = MacroLab(workspace: workspace.map { URL(fileURLWithPath: $0) } ?? MacroLab.defaultWorkspace, swiftPath: swift)
        let implementationSource = try String(contentsOfFile: implementation, encoding: .utf8)
        let usageSource = try String(contentsOfFile: usage, encoding: .utf8)
        let declarationSource = try declarations.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let types = MacroLab.discoverMacroTypes(in: implementationSource)
        FileHandle.standardError.write(Data(Terminal.dim("Found \(types.count) macro type(s): \(types.map { "\($0.typeName) (\($0.roles.map(\.rawValue).joined(separator: ",")))" }.joined(separator: ", "))\nBuilding in \(lab.workspace.path) …\n").utf8))
        let (build, report) = lab.run(implementation: implementationSource, usage: usageSource, declarations: declarationSource, fileName: usage)
        guard build.succeeded, let report else {
            for diagnostic in build.diagnostics { Terminal.printDiagnostic(diagnostic, fileName: implementation) }
            if build.diagnostics.isEmpty { FileHandle.standardError.write(Data(build.log.utf8)) }
            throw ExitCode(1)
        }
        FileHandle.standardError.write(Data(Terminal.dim("Built in \(String(format: "%.1f", build.durationMilliseconds / 1000)) s\n").utf8))
        switch format {
        case .json: print(try Terminal.json(report))
        case .full: print(report.expandedSource)
        case .diff: print(Terminal.colorizedDiff(report.unifiedDiff))
        case .expansions:
            for record in report.expansions {
                print(Terminal.bold(record.spelling) + Terminal.dim(" \(record.role.rawValue)"))
                print(record.expandedSource + "\n")
            }
        }
        for diagnostic in report.diagnostics { Terminal.printDiagnostic(diagnostic, fileName: usage) }
        if report.hasErrors { throw ExitCode(1) }
    }
}

// MARK: - migrate-previews

struct MigratePreviews: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert PreviewProvider structs into #Preview macros.")

    @Argument(help: "Swift file.")
    var file: String

    @Flag(help: "Rewrite the file instead of printing the result.")
    var inPlace = false

    func run() throws {
        let source = try String(contentsOfFile: file, encoding: .utf8)
        guard let converted = PreviewMigrator.convertPreviewProvidersToMacros(source) else {
            FileHandle.standardError.write(Data("No PreviewProvider found.\n".utf8))
            return
        }
        if inPlace {
            try converted.write(toFile: file, atomically: true, encoding: .utf8)
        } else {
            print(converted, terminator: "")
        }
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the toolchain, plugins and built-in macros SwiftLens found.")

    func run() throws {
        print(Terminal.bold("SwiftLens \(SwiftLensVersion.current)"))
        guard let toolchain = Toolchain.detect() else {
            print(Terminal.red("✗ No Swift toolchain found.") + " Install Xcode / Swift, or set SWIFTLENS_TOOLCHAIN to a toolchain root.")
            throw ExitCode(1)
        }
        print(toolchain.description)
        let plugins = toolchain.libraryPlugins()
        print("\n" + Terminal.bold("Library plugins (\(plugins.count))"))
        for (module, path) in plugins.sorted(by: { $0.key < $1.key }) { print("  \(module)  " + Terminal.dim(path)) }
        let registry = MacroRegistry()
        registry.addToolchainMacros(toolchain)
        let definitions = registry.allDefinitions
        print("\n" + Terminal.bold("Built-in macros (\(definitions.count))"))
        for definition in definitions {
            let ok = plugins[definition.moduleName] != nil
            print("  \(ok ? Terminal.green("✓") : Terminal.yellow("?")) \(definition.isFreestanding ? "#" : "@")\(definition.name) " + Terminal.dim("\(definition.declaringModule ?? "") → \(definition.moduleName).\(definition.typeName)"))
        }
        #if os(macOS)
        print("\n" + Terminal.green("✓ ") + "SwiftUI rendering available")
        #else
        print("\n" + Terminal.yellow("• ") + "SwiftUI rendering requires macOS (macro tools work here)")
        #endif
    }
}
