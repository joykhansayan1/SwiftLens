import Foundation
import SwiftLensCore
import SwiftParser
import SwiftSyntax

/// What a `macro` declaration says about a macro: its roles and which plugin type implements it.
public struct MacroDefinition: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case expression, declaration, codeItem
        case accessor, memberAttribute, member, peer, conformance, `extension`, preamble, body

        public var isFreestanding: Bool { [.expression, .declaration, .codeItem].contains(self) }
    }

    /// The macro's name as used at the call site (`stringify`, `Observable`).
    public var name: String
    /// The plugin module that implements it (`ObservationMacros`).
    public var moduleName: String
    /// The implementation type inside the plugin (`ObservableMacro`).
    public var typeName: String
    public var roles: [Role]
    /// Conformances listed in `@attached(extension, conformances: ...)`.
    public var conformances: [String]
    /// Argument labels of the declaration's parameters (`nil` for unlabeled), used to pick between overloads.
    public var parameterLabels: [String?]
    /// Whether the last parameter is a closure, which allows trailing-closure call syntax.
    public var acceptsTrailingClosure: Bool
    /// The module whose interface/source declares the macro (`Observation`), when known.
    public var declaringModule: String?
    /// The full declaration text.
    public var declaration: String
    /// Where the declaration was found.
    public var origin: String

    public var isFreestanding: Bool { roles.contains { $0.isFreestanding } }

    public var description: String {
        let kind = isFreestanding ? "#" : "@"
        let roleList = roles.map(\.rawValue).joined(separator: ", ")
        return "\(kind)\(name) → \(moduleName).\(typeName) [\(roleList)]"
    }
}

/// Extracts `macro` declarations from Swift sources and `.swiftinterface` files.
public enum MacroDeclarationScanner {
    public static func scan(source: String, origin: String, declaringModule: String? = nil) -> [MacroDefinition] {
        let tree = Parser.parse(source: source)
        let visitor = Visitor(origin: origin, declaringModule: declaringModule)
        visitor.walk(tree)
        return visitor.definitions
    }

    /// Fast path for huge interface files (SwiftUI's is several MB): only lines mentioning `#externalMacro`
    /// (plus attribute-only lines directly preceding them) are parsed.
    public static func scanInterface(text: String, origin: String, declaringModule: String?) -> [MacroDefinition] {
        guard text.contains("#externalMacro") else { return [] }
        var snippet: [Substring] = []
        var pendingAttributes: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if line.contains("#externalMacro") {
                snippet.append(contentsOf: pendingAttributes)
                snippet.append(line)
                pendingAttributes.removeAll()
            } else if trimmed.hasPrefix("@") && !trimmed.contains("{") {
                pendingAttributes.append(line)
                if pendingAttributes.count > 16 { pendingAttributes.removeFirst() }
            } else {
                pendingAttributes.removeAll()
            }
        }
        return scan(source: snippet.joined(separator: "\n"), origin: origin, declaringModule: declaringModule)
    }

    public static func scan(fileAt path: String, declaringModule: String? = nil) -> [MacroDefinition] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        if path.hasSuffix(".swiftinterface") {
            return scanInterface(text: text, origin: path, declaringModule: declaringModule ?? moduleName(fromInterfacePath: path))
        }
        guard text.contains("macro") else { return [] }
        return scan(source: text, origin: path, declaringModule: declaringModule)
    }

    static func moduleName(fromInterfacePath path: String) -> String? {
        let components = path.split(separator: "/")
        if let module = components.last(where: { $0.hasSuffix(".swiftmodule") }) {
            return String(module.dropLast(".swiftmodule".count))
        }
        return components.last.map { String($0.split(separator: ".").first ?? $0) }
    }

    final class Visitor: SyntaxVisitor {
        let origin: String
        let declaringModule: String?
        var definitions: [MacroDefinition] = []

        init(origin: String, declaringModule: String?) {
            self.origin = origin
            self.declaringModule = declaringModule
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let definition = node.definition?.value.as(MacroExpansionExprSyntax.self),
                  definition.macroName.text == "externalMacro"
            else { return .skipChildren }

            func stringArgument(_ label: String) -> String? {
                guard let argument = definition.arguments.first(where: { $0.label?.text == label }),
                      let literal = argument.expression.as(StringLiteralExprSyntax.self)
                else { return nil }
                return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
            }
            guard let module = stringArgument("module"), let type = stringArgument("type") else { return .skipChildren }

            var roles: [MacroDefinition.Role] = []
            var conformances: [String] = []
            for element in node.attributes {
                guard let attribute = element.as(AttributeSyntax.self) else { continue }
                let attributeName = attribute.attributeName.trimmedDescription
                guard attributeName == "freestanding" || attributeName == "attached",
                      case .argumentList(let arguments) = attribute.arguments,
                      let first = arguments.first
                else { continue }
                let roleName = first.expression.trimmedDescription
                if let role = MacroDefinition.Role(rawValue: roleName) {
                    if !roles.contains(role) { roles.append(role) }
                }
                for argument in arguments where argument.label?.text == "conformances" {
                    conformances.append(argument.expression.trimmedDescription)
                }
                // `conformances:` takes a variadic list: subsequent unlabeled arguments belong to it.
                var inConformances = false
                for argument in arguments {
                    if let label = argument.label?.text { inConformances = label == "conformances"; continue }
                    if inConformances { conformances.append(argument.expression.trimmedDescription) }
                }
            }
            guard !roles.isEmpty else { return .skipChildren }

            let parameters = node.signature.parameterClause.parameters
            let labels: [String?] = parameters.map { parameter in
                let first = parameter.firstName.text
                return first == "_" ? nil : first
            }
            let lastIsClosure = parameters.last.map { parameter in
                let type = parameter.type.trimmedDescription
                return type.contains("->")
            } ?? false

            definitions.append(MacroDefinition(
                name: node.name.text,
                moduleName: module,
                typeName: type,
                roles: roles,
                conformances: conformances,
                parameterLabels: labels,
                acceptsTrailingClosure: lastIsClosure,
                declaringModule: declaringModule,
                declaration: node.trimmedDescription,
                origin: origin
            ))
            return .skipChildren
        }
    }
}
