import Foundation
import SwiftLensCore
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion

/// One macro expansion performed while expanding a file.
public struct ExpansionRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var macroName: String
    /// `#name` / `@Name`.
    public var spelling: String
    public var role: MacroDefinition.Role
    public var moduleName: String
    public var typeName: String
    /// Position of the macro use in the original file. `nil` for macros that only appear in generated code.
    public var position: SourcePosition?
    /// Short description of the declaration an attached macro is attached to.
    public var attachedTo: String?
    public var expandedSource: String
    /// `true` when the macro was found inside another macro's expansion.
    public var isNested: Bool
    public var diagnostics: [LensDiagnostic]
    public var durationMilliseconds: Double
}

/// The result of expanding every macro in a file.
public struct ExpansionReport: Codable, Sendable {
    public var fileName: String
    public var originalSource: String
    /// The whole file with every macro expanded in place — something neither Xcode nor the compiler offer.
    public var expandedSource: String
    public var expansions: [ExpansionRecord]
    public var diagnostics: [LensDiagnostic]
    /// Macro-looking uses (`#foo`, `@Foo`) with no known declaration; usually a missing `--decls` path.
    public var unresolvedMacros: [MacroUsage]
    public var usages: [MacroUsage]
    public var durationMilliseconds: Double

    public var unifiedDiff: String {
        TextDiff.unified(from: originalSource, to: expandedSource, oldName: "a/\(fileName)", newName: "b/\(fileName) (expanded)")
    }

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

public struct MacroExpansionOptions: Sendable {
    /// Module name reported to macros (`#fileID`, `context.location`).
    public var moduleName: String = "SwiftLensSnippet"
    /// Only expand toolchain macros whose declaring module is imported (directly or via a re-export).
    public var respectImports: Bool = true
    /// Rewrite compiler-style unique names (`$s…6MemberfMu_`) into readable ones (`__Member_1`).
    public var readableUniqueNames: Bool = true
    /// Indentation used when splicing expansions; `nil` infers it from the file.
    public var indentationWidth: Int? = nil

    public init(moduleName: String = "SwiftLensSnippet", respectImports: Bool = true, readableUniqueNames: Bool = true, indentationWidth: Int? = nil) {
        self.moduleName = moduleName
        self.respectImports = respectImports
        self.readableUniqueNames = readableUniqueNames
        self.indentationWidth = indentationWidth
    }
}

public enum MacroEngineError: Error, CustomStringConvertible {
    case unknownMacro(String)
    case expansionFailed(String, [String])
    case noSession

    public var description: String {
        switch self {
        case .unknownMacro(let name): "No declaration found for macro '\(name)'"
        case .expansionFailed(let name, let messages):
            "Expansion of '\(name)' failed" + (messages.isEmpty ? "" : ": " + messages.joined(separator: "; "))
        case .noSession: "Macro proxy invoked outside of an expansion session"
        }
    }
}

/// Expands every macro in a Swift file by driving the real macro plugins (executables, or toolchain libraries via
/// `swift-plugin-server`) through swift-syntax's `MacroSystem`. No build of the surrounding project is needed.
public final class MacroExpander {
    public let registry: MacroRegistry
    public let host: MacroPluginHost

    public init(registry: MacroRegistry, host: MacroPluginHost) {
        self.registry = registry
        self.host = host
    }

    /// Creates an expander wired to the active toolchain with its built-in macros pre-registered.
    public static func withToolchainDefaults(configuration: MacroPluginHost.Configuration = .init(), declarationPaths: [String] = []) -> MacroExpander {
        let toolchain = Toolchain.detect()
        let registry = MacroRegistry()
        if let toolchain { registry.addToolchainMacros(toolchain) }
        registry.addDeclarations(fromPaths: declarationPaths)
        return MacroExpander(registry: registry, host: MacroPluginHost(configuration: configuration, toolchain: toolchain))
    }

    public func expand(source: String, fileName: String = "Snippet.swift", options: MacroExpansionOptions = .init()) -> ExpansionReport {
        expand(SourceDocument(text: source, fileName: fileName), options: options)
    }

    public func expand(_ document: SourceDocument, options: MacroExpansionOptions = .init()) -> ExpansionReport {
        let start = DispatchTime.now()
        // Declarations in the file itself are visible to it.
        registry.addDeclarations(source: document.text, origin: document.fileName)

        let usages = MacroUsageScanner.scan(document)
        let available = availableDefinitions(for: document, options: options)

        var specs: [String: MacroSpec] = [:]
        for (name, definitions) in available {
            guard let type = ProxyFactory.proxyType(for: definitions) else { continue }
            let conformances = definitions.flatMap(\.conformances).compactMap { text -> TypeSyntax? in
                var parser = Parser(text)
                return TypeSyntax.parse(from: &parser)
            }
            specs[name] = MacroSpec(type: type, conformances: conformances)
        }

        let session = ExpansionSession(document: document, registry: registry, available: available, host: host, options: options)
        // Same text, different trivia layout (see `NewlineTriviaSplitter`).
        let prepared = NewlineTriviaSplitter(viewMode: .all).rewrite(document.tree).cast(SourceFileSyntax.self)
        let baseContext = BasicMacroExpansionContext(
            sourceFiles: [prepared: .init(moduleName: options.moduleName, fullFilePath: document.fileName)]
        )
        let expanded: Syntax = ExpansionSession.$current.withValue(session) {
            prepared.expand(
                macroSpecs: specs,
                contextGenerator: { node in
                    BasicMacroExpansionContext(sharingWith: baseContext, lexicalContext: node.allMacroLexicalContexts())
                },
                indentationWidth: options.indentationWidth.map { Trivia.spaces($0) }
            )
        }

        var expandedText = expanded.description
        // An attribute that is the very first token leaves the following newline behind.
        if !document.text.hasPrefix("\n"), expandedText.hasPrefix("\n") {
            expandedText = String(expandedText.drop(while: { $0 == "\n" }))
        }
        var records = session.records
        if options.readableUniqueNames {
            let prettifier = UniqueNamePrettifier()
            expandedText = prettifier.rewrite(expandedText)
            for index in records.indices { records[index].expandedSource = prettifier.rewrite(records[index].expandedSource) }
        }

        var diagnostics = document.parserDiagnostics + session.diagnostics
        let known = Set(session.diagnostics.map(\.message))
        for diagnostic in baseContext.diagnostics where !known.contains(where: { diagnostic.message.contains($0) }) {
            let inOriginal = diagnostic.node.root.is(SourceFileSyntax.self) && diagnostic.node.root.description == document.text
            diagnostics.append(LensDiagnostic(
                severity: LensSeverity(diagnostic.diagMessage.severity),
                message: diagnostic.message,
                position: inOriginal ? document.position(of: diagnostic.position) : nil,
                origin: .macro
            ))
        }

        let unresolved = usages.filter { usage in
            guard available[usage.name] == nil else { return false }
            if usage.kind == .attached {
                return !MacroUsageScanner.wellKnownNonMacroAttributes.contains(usage.name) && registry.definitions(named: usage.name).isEmpty
            }
            return true
        }

        return ExpansionReport(
            fileName: document.fileName,
            originalSource: document.text,
            expandedSource: expandedText,
            expansions: records,
            diagnostics: diagnostics,
            unresolvedMacros: unresolved,
            usages: usages,
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        )
    }

    /// Macro definitions visible in the document, keyed by name.
    func availableDefinitions(for document: SourceDocument, options: MacroExpansionOptions) -> [String: [MacroDefinition]] {
        let imported = ImportGraph.visibleModules(importedBy: document)
        var result: [String: [MacroDefinition]] = [:]
        for definition in registry.allDefinitions {
            if options.respectImports, let module = definition.declaringModule, !imported.contains(module) { continue }
            result[definition.name, default: []].append(definition)
        }
        return result
    }
}

/// Which modules a file can see, including well-known re-exports (e.g. SwiftUI re-exports Observation).
enum ImportGraph {
    static let alwaysVisible: Set<String> = ["Swift", "_Concurrency", "_StringProcessing", "Synchronization"]
    static let reexports: [String: [String]] = [
        "SwiftUI": ["SwiftUICore", "DeveloperToolsSupport", "Observation", "Foundation", "Combine"],
        "SwiftUICore": ["DeveloperToolsSupport", "Observation", "Foundation"],
        "SwiftData": ["Observation", "Foundation", "CoreData"],
        "Foundation": ["FoundationEssentials"],
        "UIKit": ["Foundation", "DeveloperToolsSupport"],
        "AppKit": ["Foundation", "DeveloperToolsSupport"],
        "WidgetKit": ["SwiftUI"],
        "RealityKit": ["Foundation"],
        "Charts": ["SwiftUI"],
        "MapKit": ["Foundation"],
        "TipKit": ["Foundation"],
        "AppIntents": ["Foundation"],
    ]

    static func visibleModules(importedBy document: SourceDocument) -> Set<String> {
        var queue: [String] = []
        for statement in document.tree.statements {
            if let importDecl = statement.item.as(ImportDeclSyntax.self), let first = importDecl.path.first {
                queue.append(first.name.text)
            }
        }
        var visible = alwaysVisible
        while let module = queue.popLast() {
            guard visible.insert(module).inserted else { continue }
            queue += reexports[module] ?? []
        }
        return visible
    }
}

/// Per-expansion state shared with the proxy macro types through a task-local.
final class ExpansionSession {
    @TaskLocal static var current: ExpansionSession?

    let document: SourceDocument
    let registry: MacroRegistry
    let available: [String: [MacroDefinition]]
    let host: MacroPluginHost
    let options: MacroExpansionOptions
    var records: [ExpansionRecord] = []
    var diagnostics: [LensDiagnostic] = []
    private var counter = 0

    init(document: SourceDocument, registry: MacroRegistry, available: [String: [MacroDefinition]], host: MacroPluginHost, options: MacroExpansionOptions) {
        self.document = document
        self.registry = registry
        self.available = available
        self.host = host
        self.options = options
    }

    // MARK: Resolution

    private func resolve(name: String, attached: Bool, labels: [String?], trailingClosure: Bool, role: MacroDefinition.Role) throws -> MacroDefinition {
        let candidates = (available[name] ?? []).filter { $0.isFreestanding != attached }
        let withRole = candidates.filter { $0.roles.contains(role) || (role == .extension && $0.roles.contains(.conformance)) }
        let pool = withRole.isEmpty ? candidates : withRole
        guard !pool.isEmpty else { throw MacroEngineError.unknownMacro(name) }
        if pool.count == 1 { return pool[0] }
        let scratch = MacroRegistry(pool)
        return scratch.resolve(name: name, attached: attached, labels: labels, hasTrailingClosure: trailingClosure) ?? pool[0]
    }

    // MARK: Locations

    private var fileID: String {
        "\(options.moduleName)/\((document.fileName as NSString).lastPathComponent)"
    }

    private lazy var usages: [MacroUsage] = MacroUsageScanner.scan(document)
    private var consumedFreestanding: Set<Int> = []
    private lazy var utf8 = Array(document.text.utf8)

    private func text(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= utf8.count else { return nil }
        return String(decoding: utf8[offset..<(offset + length)], as: UTF8.self)
    }

    /// Location (start of the trimmed node) of `node` in the original file, or `nil` when the node only exists in
    /// generated code.
    ///
    /// MacroSystem hands macros detached copies, sometimes taken from a partially rewritten tree, so the location
    /// reported by the context is validated against the original text and otherwise recovered from the scanned
    /// macro uses (disambiguated by the declaration they are attached to).
    func originalLocation(of node: some SyntaxProtocol, in context: some MacroExpansionContext, attachedToHint: String? = nil) -> SourcePosition? {
        let trimmed = node.trimmedDescription
        let length = trimmed.utf8.count
        if let basic = context as? BasicMacroExpansionContext,
           basic.location(of: node, at: .afterLeadingTrivia, filePathMode: .filePath) != nil {
            let location = basic.location(for: node.positionAfterSkippingLeadingTrivia, anchoredAt: Syntax(node), fileName: document.fileName)
            if text(at: location.offset, length: length) == trimmed {
                let position = SourcePosition(line: location.line, column: location.column, offset: location.offset)
                let isAttributeOnOtherDeclaration = node.is(AttributeSyntax.self) && attachedToHint != nil &&
                    usages.contains { $0.span.start == position && $0.attachedTo?.name != attachedToHint }
                if !isAttributeOnOtherDeclaration { return position }
            }
        }
        let isAttribute = node.is(AttributeSyntax.self)
        let candidates = usages.filter { usage in
            (usage.kind == .attached) == isAttribute &&
                text(at: usage.span.start.offset, length: usage.span.length) == trimmed
        }
        if isAttribute {
            // The same attribute text may appear on generated declarations (e.g. `@ObservationIgnored` on `_count`),
            // so require the attached declaration to match when we know it.
            guard let attachedToHint else { return candidates.first?.span.start }
            return candidates.first { $0.attachedTo?.name == attachedToHint }?.span.start
        }
        guard let chosen = candidates.first(where: { !consumedFreestanding.contains($0.id) }) ?? candidates.first else { return nil }
        consumedFreestanding.insert(chosen.id)
        return chosen.span.start
    }

    private func wireSyntax(_ node: some SyntaxProtocol, kind: PluginWire.Syntax.Kind, at position: SourcePosition?) -> PluginWire.Syntax {
        let position = position ?? SourcePosition(line: 1, column: 1, offset: 0)
        return PluginWire.Syntax(
            kind: kind,
            source: node.trimmedDescription,
            location: .init(fileID: fileID, fileName: document.fileName, offset: position.offset, line: position.line, column: position.column)
        )
    }

    /// Location of a declaration in the original file, found through the macro use attached to it.
    private func declarationLocation(of declaration: some SyntaxProtocol, attribute: SourcePosition?) -> SourcePosition? {
        guard let attribute else { return nil }
        guard let usage = usages.first(where: { $0.span.start == attribute }), let span = usage.attachedTo?.span else { return nil }
        let trimmed = declaration.trimmedDescription
        return text(at: span.start.offset, length: trimmed.utf8.count) == trimmed ? span.start : nil
    }

    private func lexicalContext(_ context: some MacroExpansionContext) -> [PluginWire.Syntax] {
        context.lexicalContext.map { node in
            let kind: PluginWire.Syntax.Kind = node.is(ExprSyntax.self) ? .expression : .declaration
            return PluginWire.Syntax(
                kind: kind,
                source: node.description,
                location: .init(fileID: fileID, fileName: document.fileName, offset: 0, line: 1, column: 1)
            )
        }
    }

    private func nextDiscriminator(_ role: MacroDefinition.Role) -> String {
        counter += 1
        return "$sLens\(counter)_"
    }

    // MARK: Expansion

    func expandFreestanding(_ node: some FreestandingMacroExpansionSyntax, role: MacroDefinition.Role, context: some MacroExpansionContext) throws -> String {
        let name = node.macroName.text
        let definition = try resolve(
            name: name,
            attached: false,
            labels: node.arguments.map { $0.label?.text },
            trailingClosure: node.trailingClosure != nil,
            role: role
        )
        let kind: PluginWire.Syntax.Kind = node.is(MacroExpansionExprSyntax.self) ? .expression : .declaration
        let position = originalLocation(of: node, in: context)
        let message = HostToPluginMessage.expandFreestandingMacro(
            macro: .init(moduleName: definition.moduleName, typeName: definition.typeName, name: name),
            macroRole: PluginWire.MacroRole(rawValue: role.rawValue),
            discriminator: nextDiscriminator(role),
            syntax: wireSyntax(node, kind: kind, at: position),
            lexicalContext: lexicalContext(context)
        )
        return try perform(message, definition: definition, role: role, spelling: "#" + name, position: position, attachedTo: nil)
    }

    func expandAttached(
        role: MacroDefinition.Role,
        attribute: AttributeSyntax,
        declaration: some SyntaxProtocol,
        parent: Syntax?,
        extendedType: TypeSyntax?,
        conformances: [TypeSyntax],
        context: some MacroExpansionContext
    ) throws -> String {
        let name = attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
        var labels: [String?] = []
        if case .argumentList(let list) = attribute.arguments { labels = list.map { $0.label?.text } }
        let definition = try resolve(name: name, attached: true, labels: labels, trailingClosure: false, role: role)

        var conformanceList: PluginWire.Syntax?
        if role == .extension || role == .conformance {
            // Drop protocols the type already states (the compiler does this semantically).
            let stated = Set(declaration.as(DeclSyntax.self)?.asProtocol(DeclGroupSyntax.self)?.inheritanceClause?.inheritedTypes.map {
                $0.type.trimmedDescription.split(separator: ".").last.map(String.init) ?? ""
            } ?? [])
            let remaining = conformances.filter { !stated.contains($0.trimmedDescription.split(separator: ".").last.map(String.init) ?? "") }
            if !remaining.isEmpty {
                conformanceList = PluginWire.Syntax(
                    kind: .declaration,
                    source: "struct __SwiftLensConformances: \(remaining.map(\.trimmedDescription).joined(separator: ", ")) {}",
                    location: .init(fileID: fileID, fileName: document.fileName, offset: 0, line: 1, column: 1)
                )
            }
        }

        let wireRole: PluginWire.MacroRole = PluginWire.MacroRole(rawValue: role.rawValue) ?? .peer
        let target = parent ?? Syntax(declaration)
        let position = originalLocation(of: attribute, in: context, attachedToHint: SyntaxTreeBuilder.summary(of: target))
        let declarationPosition = declarationLocation(of: target, attribute: position)
        let message = HostToPluginMessage.expandAttachedMacro(
            macro: .init(moduleName: definition.moduleName, typeName: definition.typeName, name: name),
            macroRole: wireRole,
            discriminator: nextDiscriminator(role),
            attributeSyntax: wireSyntax(attribute, kind: .attribute, at: position),
            declSyntax: wireSyntax(declaration, kind: declaration.is(AccessorDeclSyntax.self) ? .accessor : .declaration, at: parent == nil ? declarationPosition : nil),
            parentDeclSyntax: parent.map { wireSyntax($0, kind: .declaration, at: declarationPosition) },
            extendedTypeSyntax: extendedType.map { wireSyntax($0, kind: .type, at: nil) },
            conformanceListSyntax: conformanceList,
            lexicalContext: lexicalContext(context)
        )
        let summary = MacroUsageScanner.describeDeclaration(target)
        return try perform(message, definition: definition, role: role, spelling: "@" + name, position: position, attachedTo: summary)
    }

    private func perform(
        _ message: HostToPluginMessage,
        definition: MacroDefinition,
        role: MacroDefinition.Role,
        spelling: String,
        position: SourcePosition?,
        attachedTo: String?
    ) throws -> String {
        let started = DispatchTime.now()
        let isNested = position == nil

        func fail(_ text: String) -> Error {
            let diagnostic = LensDiagnostic(severity: .error, message: text, position: position, origin: .macro, macroName: definition.name)
            diagnostics.append(diagnostic)
            return MacroEngineError.expansionFailed(definition.name, [text])
        }

        let connection: PluginConnection
        do {
            connection = try host.connection(for: definition.moduleName)
        } catch {
            throw fail("\(error)")
        }

        let response: PluginToHostMessage
        do {
            response = try connection.request(message)
        } catch {
            throw fail("\(error)")
        }

        let expandedSource: String?
        let wireDiagnostics: [PluginWire.Diagnostic]
        switch response {
        case .expandMacroResult(let source, let diags), .expandFreestandingMacroResult(let source, let diags):
            expandedSource = source
            wireDiagnostics = diags
        case .expandAttachedMacroResult(let sources, let diags):
            expandedSource = sources?.joined(separator: role == .memberAttribute ? " " : "\n\n")
            wireDiagnostics = diags
        default:
            throw fail("unexpected plugin response")
        }

        let converted = wireDiagnostics.map { convert($0, macro: definition.name, nested: isNested) }
        diagnostics += converted

        guard let expandedSource else {
            throw MacroEngineError.expansionFailed(definition.name, converted.map(\.message))
        }
        records.append(ExpansionRecord(
            id: records.count,
            macroName: definition.name,
            spelling: spelling,
            role: role,
            moduleName: definition.moduleName,
            typeName: definition.typeName,
            position: position,
            attachedTo: attachedTo,
            expandedSource: expandedSource,
            isNested: isNested,
            diagnostics: converted,
            durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        ))
        return expandedSource
    }

    private func convert(_ diagnostic: PluginWire.Diagnostic, macro: String, nested: Bool) -> LensDiagnostic {
        func position(_ offset: Int, file: String) -> SourcePosition? {
            guard !nested, file == document.fileName else { return nil }
            return document.position(atOffset: offset)
        }
        func span(_ range: PluginWire.Diagnostic.PositionRange) -> SourceSpan? {
            guard let start = position(range.startOffset, file: range.fileName),
                  let end = position(range.endOffset, file: range.fileName) else { return nil }
            return SourceSpan(start: start, end: end)
        }
        let severity: LensSeverity = switch diagnostic.severity {
        case .error: .error
        case .warning: .warning
        case .note: .note
        case .remark: .remark
        }
        return LensDiagnostic(
            severity: severity,
            message: diagnostic.message,
            position: position(diagnostic.position.offset, file: diagnostic.position.fileName),
            highlights: diagnostic.highlights.compactMap(span),
            notes: diagnostic.notes.map(\.message),
            fixIts: diagnostic.fixIts.map { fixIt in
                LensFixIt(message: fixIt.message, edits: fixIt.changes.compactMap { change in
                    span(change.range).map { LensFixIt.Edit(span: $0, replacement: change.newText) }
                })
            },
            origin: .macro,
            macroName: macro
        )
    }
}

extension MacroUsageScanner {
    static func describeDeclaration(_ node: Syntax) -> String {
        let kind = "\(node.syntaxNodeType)".replacingOccurrences(of: "DeclSyntax", with: "").lowercased()
        if let summary = SyntaxTreeBuilder.summary(of: node) { return "\(kind) \(summary)" }
        return kind
    }
}
