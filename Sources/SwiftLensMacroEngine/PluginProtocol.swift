// Wire format of the Swift compiler <-> macro plugin protocol.
//
// These types mirror `HostToPluginMessage` / `PluginToHostMessage` from swift-syntax's
// `SwiftCompilerPluginMessageHandling` module. They are re-declared here (instead of importing the
// underscored SPI product) so that SwiftLens can talk to plugins built against *any* swift-syntax version:
// the protocol is versioned and backwards compatible, the Swift API used to model it is not.
//
// Framing: every message is a little-endian UInt64 byte count followed by that many bytes of JSON.
// Enums with associated values use Swift's synthesized Codable layout: `{"caseName": {"label": value}}`.

enum HostToPluginMessage: Encodable {
    case getCapability(capability: PluginWire.HostCapability?)
    case expandFreestandingMacro(
        macro: PluginWire.MacroReference,
        macroRole: PluginWire.MacroRole?,
        discriminator: String,
        syntax: PluginWire.Syntax,
        lexicalContext: [PluginWire.Syntax]?
    )
    case expandAttachedMacro(
        macro: PluginWire.MacroReference,
        macroRole: PluginWire.MacroRole,
        discriminator: String,
        attributeSyntax: PluginWire.Syntax,
        declSyntax: PluginWire.Syntax,
        parentDeclSyntax: PluginWire.Syntax?,
        extendedTypeSyntax: PluginWire.Syntax?,
        conformanceListSyntax: PluginWire.Syntax?,
        lexicalContext: [PluginWire.Syntax]?
    )
    case loadPluginLibrary(libraryPath: String, moduleName: String)
}

enum PluginToHostMessage: Decodable {
    case getCapabilityResult(capability: PluginWire.PluginCapability)
    case expandMacroResult(expandedSource: String?, diagnostics: [PluginWire.Diagnostic])
    case expandFreestandingMacroResult(expandedSource: String?, diagnostics: [PluginWire.Diagnostic])
    case expandAttachedMacroResult(expandedSources: [String]?, diagnostics: [PluginWire.Diagnostic])
    case loadPluginLibraryResult(loaded: Bool, diagnostics: [PluginWire.Diagnostic])
}

enum PluginWire {
    /// Protocol version spoken by SwiftLens. 8 = `Syntax.Kind.accessor` support (swift-syntax 600+).
    static let protocolVersion = 8

    struct HostCapability: Codable {
        var protocolVersion: Int
    }

    struct PluginCapability: Codable {
        var protocolVersion: Int
        var features: [String]?
    }

    struct MacroReference: Codable {
        var moduleName: String
        var typeName: String
        var name: String
    }

    enum MacroRole: String, Codable {
        case expression
        case declaration
        case accessor
        case memberAttribute
        case member
        case peer
        case conformance
        case codeItem
        case `extension`
        case preamble
        case body
    }

    struct SourceLocation: Codable {
        var fileID: String
        var fileName: String
        var offset: Int
        var line: Int
        var column: Int
    }

    struct Syntax: Codable {
        enum Kind: String, Codable {
            case declaration
            case statement
            case expression
            case type
            case pattern
            case attribute
            case accessor
        }

        var kind: Kind
        var source: String
        var location: SourceLocation
    }

    struct Diagnostic: Codable {
        enum Severity: String, Codable {
            case error, warning, note, remark
        }

        struct Position: Codable {
            var fileName: String
            var offset: Int
        }

        struct PositionRange: Codable {
            var fileName: String
            var startOffset: Int
            var endOffset: Int
        }

        struct Note: Codable {
            var position: Position
            var message: String
        }

        struct FixIt: Codable {
            struct Change: Codable {
                var range: PositionRange
                var newText: String
            }

            var message: String
            var changes: [Change]
        }

        var message: String
        var severity: Severity
        var position: Position
        var highlights: [PositionRange]
        var notes: [Note]
        var fixIts: [FixIt]
    }
}

extension HostToPluginMessage {
    // Hand-written so that `nil` optionals are omitted exactly like the synthesized implementation does.
    private enum CaseKey: String, CodingKey {
        case getCapability, expandFreestandingMacro, expandAttachedMacro, loadPluginLibrary
    }

    private enum PayloadKey: String, CodingKey {
        case capability, macro, macroRole, discriminator, syntax, lexicalContext, attributeSyntax, declSyntax,
             parentDeclSyntax, extendedTypeSyntax, conformanceListSyntax, libraryPath, moduleName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .getCapability(let capability):
            var payload = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .getCapability)
            try payload.encodeIfPresent(capability, forKey: .capability)

        case .expandFreestandingMacro(let macro, let role, let discriminator, let syntax, let lexicalContext):
            var payload = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .expandFreestandingMacro)
            try payload.encode(macro, forKey: .macro)
            try payload.encodeIfPresent(role, forKey: .macroRole)
            try payload.encode(discriminator, forKey: .discriminator)
            try payload.encode(syntax, forKey: .syntax)
            try payload.encodeIfPresent(lexicalContext, forKey: .lexicalContext)

        case .expandAttachedMacro(let macro, let role, let discriminator, let attribute, let decl, let parent, let extended, let conformances, let lexicalContext):
            var payload = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .expandAttachedMacro)
            try payload.encode(macro, forKey: .macro)
            try payload.encode(role, forKey: .macroRole)
            try payload.encode(discriminator, forKey: .discriminator)
            try payload.encode(attribute, forKey: .attributeSyntax)
            try payload.encode(decl, forKey: .declSyntax)
            try payload.encodeIfPresent(parent, forKey: .parentDeclSyntax)
            try payload.encodeIfPresent(extended, forKey: .extendedTypeSyntax)
            try payload.encodeIfPresent(conformances, forKey: .conformanceListSyntax)
            try payload.encodeIfPresent(lexicalContext, forKey: .lexicalContext)

        case .loadPluginLibrary(let libraryPath, let moduleName):
            var payload = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .loadPluginLibrary)
            try payload.encode(libraryPath, forKey: .libraryPath)
            try payload.encode(moduleName, forKey: .moduleName)
        }
    }
}

extension PluginToHostMessage {
    private enum CaseKey: String, CodingKey {
        case getCapabilityResult, expandMacroResult, expandFreestandingMacroResult, expandAttachedMacroResult,
             loadPluginLibraryResult
    }

    private enum PayloadKey: String, CodingKey {
        case capability, expandedSource, expandedSources, diagnostics, loaded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Empty plugin message"))
        }
        let payload = try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
        switch key {
        case .getCapabilityResult:
            self = .getCapabilityResult(capability: try payload.decode(PluginWire.PluginCapability.self, forKey: .capability))
        case .expandMacroResult:
            self = .expandMacroResult(
                expandedSource: try payload.decodeIfPresent(String.self, forKey: .expandedSource),
                diagnostics: try payload.decodeIfPresent([PluginWire.Diagnostic].self, forKey: .diagnostics) ?? []
            )
        case .expandFreestandingMacroResult:
            self = .expandFreestandingMacroResult(
                expandedSource: try payload.decodeIfPresent(String.self, forKey: .expandedSource),
                diagnostics: try payload.decodeIfPresent([PluginWire.Diagnostic].self, forKey: .diagnostics) ?? []
            )
        case .expandAttachedMacroResult:
            self = .expandAttachedMacroResult(
                expandedSources: try payload.decodeIfPresent([String].self, forKey: .expandedSources),
                diagnostics: try payload.decodeIfPresent([PluginWire.Diagnostic].self, forKey: .diagnostics) ?? []
            )
        case .loadPluginLibraryResult:
            self = .loadPluginLibraryResult(
                loaded: try payload.decode(Bool.self, forKey: .loaded),
                diagnostics: try payload.decodeIfPresent([PluginWire.Diagnostic].self, forKey: .diagnostics) ?? []
            )
        }
    }
}
