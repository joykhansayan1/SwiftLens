import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros

// swift-syntax's `MacroSystem` decides which roles to expand by dynamically casting a macro's metatype to the
// role protocols (`as? MemberMacro.Type`, ...). SwiftLens does not have the macro implementations in-process,
// so it hands MacroSystem *proxy* types whose conformances exactly match the roles in the macro declaration.
// Every proxy forwards to the out-of-process plugin through `ExpansionSession` and re-parses the result.
//
// Attached proxies get their role set through conditional conformances on generic "switch" parameters, which
// lets SwiftLens materialise any of the 2^6 role combinations (preamble macros are an experimental feature and are not proxied) at runtime without code generation.

protocol RoleSwitch {}
enum RoleOn: RoleSwitch {}
enum RoleOff: RoleSwitch {}

struct AttachedProxy<Peer: RoleSwitch, Member: RoleSwitch, Accessor: RoleSwitch, MemberAttribute: RoleSwitch, Extension: RoleSwitch, Body: RoleSwitch>: AttachedMacro {
    static var formatMode: FormatMode { .disabled }
}

enum ExpressionProxy: ExpressionMacro {
    static var formatMode: FormatMode { .disabled }

    static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> ExprSyntax {
        let source = try session().expandFreestanding(node, role: .expression, context: context)
        return ExpansionParsing.expression(source)
    }
}

enum DeclarationProxy: DeclarationMacro {
    static var formatMode: FormatMode { .disabled }

    static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        let source = try session().expandFreestanding(node, role: .declaration, context: context)
        return ExpansionParsing.declarations(source)
    }
}

enum CodeItemProxy: CodeItemMacro {
    static var formatMode: FormatMode { .disabled }

    static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> [CodeBlockItemSyntax] {
        let source = try session().expandFreestanding(node, role: .codeItem, context: context)
        return ExpansionParsing.codeItems(source)
    }
}

private func session() throws -> ExpansionSession {
    guard let session = ExpansionSession.current else { throw MacroEngineError.noSession }
    return session
}

extension AttachedProxy: PeerMacro where Peer == RoleOn {
    static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        let source = try session().expandAttached(role: .peer, attribute: node, declaration: declaration, parent: nil, extendedType: nil, conformances: [], context: context)
        return ExpansionParsing.declarations(source)
    }
}

extension AttachedProxy: MemberMacro where Member == RoleOn {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let source = try session().expandAttached(role: .member, attribute: node, declaration: declaration, parent: nil, extendedType: nil, conformances: protocols, context: context)
        return ExpansionParsing.declarations(source)
    }
}

extension AttachedProxy: AccessorMacro where Accessor == RoleOn {
    static func expansion(of node: AttributeSyntax, providingAccessorsOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [AccessorDeclSyntax] {
        let source = try session().expandAttached(role: .accessor, attribute: node, declaration: declaration, parent: nil, extendedType: nil, conformances: [], context: context)
        return ExpansionParsing.accessors(source)
    }
}

extension AttachedProxy: MemberAttributeMacro where MemberAttribute == RoleOn {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        let source = try session().expandAttached(role: .memberAttribute, attribute: node, declaration: member, parent: Syntax(declaration), extendedType: nil, conformances: [], context: context)
        return ExpansionParsing.attributes(source)
    }
}

extension AttachedProxy: ExtensionMacro where Extension == RoleOn {
    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let source = try session().expandAttached(role: .extension, attribute: node, declaration: declaration, parent: nil, extendedType: TypeSyntax(type), conformances: protocols, context: context)
        return ExpansionParsing.extensions(source)
    }
}

extension AttachedProxy: BodyMacro where Body == RoleOn {
    static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        let source = try session().expandAttached(role: .body, attribute: node, declaration: declaration, parent: nil, extendedType: nil, conformances: [], context: context)
        return ExpansionParsing.bodyItems(source)
    }
}

enum ProxyFactory {
    /// Builds a proxy macro type for all overloads sharing a name. Returns `nil` if no role is supported.
    static func proxyType(for definitions: [MacroDefinition]) -> Macro.Type? {
        let roles = Set(definitions.flatMap(\.roles))
        if roles.contains(.expression) { return ExpressionProxy.self }
        if roles.contains(.declaration) { return DeclarationProxy.self }
        if roles.contains(.codeItem) { return CodeItemProxy.self }

        func flag(_ role: MacroDefinition.Role) -> any RoleSwitch.Type {
            roles.contains(role) ? RoleOn.self : RoleOff.self
        }
        let extensionFlag: any RoleSwitch.Type = (roles.contains(.extension) || roles.contains(.conformance)) ? RoleOn.self : RoleOff.self
        guard roles.contains(where: { !$0.isFreestanding }) else { return nil }
        return attached(flag(.peer), flag(.member), flag(.accessor), flag(.memberAttribute), extensionFlag, flag(.body))
    }

    private static func attached<A: RoleSwitch, B: RoleSwitch, C: RoleSwitch, D: RoleSwitch, E: RoleSwitch, F: RoleSwitch>(
        _ a: A.Type, _ b: B.Type, _ c: C.Type, _ d: D.Type, _ e: E.Type, _ f: F.Type
    ) -> Macro.Type {
        AttachedProxy<A, B, C, D, E, F>.self
    }
}

/// Turns the (collapsed) source text returned by a plugin back into the node lists MacroSystem expects.
enum ExpansionParsing {
    static func expression(_ source: String) -> ExprSyntax {
        var parser = Parser(source)
        return ExprSyntax.parse(from: &parser)
    }

    static func declarations(_ source: String) -> [DeclSyntax] {
        // Parse as the members of a type so that `init`, `subscript` and `deinit` are accepted.
        let wrapped = "struct __SwiftLensWrapper {\n\(source)\n}"
        let file = Parser.parse(source: wrapped)
        guard let wrapper = file.statements.first?.item.as(StructDeclSyntax.self) else { return [] }
        return wrapper.memberBlock.members.map { member in
            var decl = member.decl
            decl.leadingTrivia = decl.leadingTrivia.droppingLeadingNewlines()
            return decl
        }
    }

    static func extensions(_ source: String) -> [ExtensionDeclSyntax] {
        Parser.parse(source: source).statements.compactMap { item in
            item.item.as(ExtensionDeclSyntax.self).map { decl in
                var decl = decl
                decl.leadingTrivia = decl.leadingTrivia.droppingLeadingNewlines()
                return decl
            }
        }
    }

    static func codeItems(_ source: String) -> [CodeBlockItemSyntax] {
        Array(Parser.parse(source: source).statements)
    }

    static func bodyItems(_ source: String) -> [CodeBlockItemSyntax] {
        let trimmed = source.trimmingWhitespace()
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            let file = Parser.parse(source: "func __swiftLensBody() \(trimmed)")
            if let function = file.statements.first?.item.as(FunctionDeclSyntax.self), let body = function.body {
                return Array(body.statements)
            }
        }
        return codeItems(source)
    }

    static func accessors(_ source: String) -> [AccessorDeclSyntax] {
        let trimmed = source.trimmingWhitespace()
        let block = trimmed.hasPrefix("{") ? trimmed : "{\n\(trimmed)\n}"
        let file = Parser.parse(source: "var __swiftLensAccessors: Int \(block)")
        guard let variable = file.statements.first?.item.as(VariableDeclSyntax.self),
              let accessorBlock = variable.bindings.first?.accessorBlock
        else { return [] }
        switch accessorBlock.accessors {
        case .accessors(let list):
            return Array(list)
        case .getter(let items):
            return [AccessorDeclSyntax(accessorSpecifier: .keyword(.get), body: CodeBlockSyntax(statements: items))]
        }
    }

    static func attributes(_ source: String) -> [AttributeSyntax] {
        let file = Parser.parse(source: "\(source) var __swiftLensAttributes: Int")
        guard let variable = file.statements.first?.item.as(VariableDeclSyntax.self) else { return [] }
        return variable.attributes.compactMap { $0.as(AttributeSyntax.self)?.trimmed }
    }
}

extension Trivia {
    func droppingLeadingNewlines() -> Trivia {
        Trivia(pieces: Array(pieces.drop(while: { $0.isNewline || $0.isSpaceOrTab })))
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }
}

extension TriviaPiece {
    var isSpaceOrTab: Bool {
        switch self {
        case .spaces, .tabs: true
        default: false
        }
    }
}
