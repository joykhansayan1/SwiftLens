// Sample macros used by SwiftLens' tests and README walkthrough.
//
// Build with `swift build --product SwiftLensDemoMacros`, then point SwiftLens at it:
//   swiftlens expand Examples/DemoMacros/Usage.swift \
//     --plugin .build/debug/SwiftLensDemoMacros#SwiftLensDemoMacros \
//     --decls Examples/DemoMacros/Declarations.swift

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct SwiftLensDemoMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StringifyMacro.self,
        MemberwiseInitMacro.self,
        AutoDescriptionMacro.self,
        AddAsyncMacro.self,
        UserDefaultMacro.self,
        ConstantsMacro.self,
    ]
}

/// `#stringify(a + b)` → `(a + b, "a + b")`
public struct StringifyMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) -> ExprSyntax {
        guard let argument = node.arguments.first?.expression else {
            fatalError("compiler bug: the macro does not have any arguments")
        }
        return "(\(argument), \(literal: argument.description))"
    }
}

struct DemoDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.diagnosticID = MessageID(domain: "SwiftLensDemoMacros", id: id)
        self.severity = severity
    }
}

struct DemoFixIt: FixItMessage {
    let message: String
    var fixItID: MessageID { MessageID(domain: "SwiftLensDemoMacros", id: message) }
}

/// `@MemberwiseInit` on a struct/class → a public memberwise initializer.
public struct MemberwiseInitMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: node,
                message: DemoDiagnostic("@MemberwiseInit can only be applied to a struct or class", id: "notAType"),
                fixIt: FixIt(message: DemoFixIt(message: "Remove '@MemberwiseInit'"), changes: [
                    .replace(oldNode: Syntax(node), newNode: Syntax(TokenSyntax(.stringSegment(""), presence: .present))),
                ])
            ))
            return []
        }
        var parameters: [String] = []
        var assignments: [String] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else { continue }
            for binding in variable.bindings where binding.accessorBlock == nil {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                if variable.bindingSpecifier.tokenKind == .keyword(.let), binding.initializer != nil { continue }
                let defaultValue = binding.initializer.map { " = \($0.value.trimmedDescription)" } ?? ""
                parameters.append("\(name): \(type)\(defaultValue)")
                assignments.append("self.\(name) = \(name)")
            }
        }
        let body = assignments.map { "    " + $0 }.joined(separator: "\n")
        return ["public init(\(raw: parameters.joined(separator: ", "))) {\n\(raw: body)\n}"]
    }
}

/// `@AutoDescription` → `extension T: CustomStringConvertible { var description: String { ... } }`
public struct AutoDescriptionMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        let names = declaration.memberBlock.members.compactMap { member -> String? in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else { return nil }
            return variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        }
        let fields = names.map { "\($0): \\(\($0))" }.joined(separator: ", ")
        let typeName = type.trimmedDescription
        let decl: DeclSyntax = """
            extension \(raw: typeName): CustomStringConvertible {
                public var description: String {
                    "\(raw: typeName)(\(raw: fields))"
                }
            }
            """
        return [decl.cast(ExtensionDeclSyntax.self)]
    }
}

/// `@AddAsync` on `func f(..., completion: @escaping (T) -> Void)` → an `async` overload returning `T`.
public struct AddAsyncMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self),
              let completion = function.signature.parameterClause.parameters.last,
              let closureType = completion.type.as(AttributedTypeSyntax.self)?.baseType.as(FunctionTypeSyntax.self)
                ?? completion.type.as(FunctionTypeSyntax.self)
        else {
            context.diagnose(Diagnostic(node: node, message: DemoDiagnostic("@AddAsync requires a function whose last parameter is a completion handler", id: "noCompletion")))
            return []
        }
        let resultType = closureType.parameters.first?.type.trimmedDescription ?? "Void"
        let parameters = function.signature.parameterClause.parameters.dropLast()
        let parameterList = parameters.map { $0.with(\.trailingComma, nil).trimmedDescription }.joined(separator: ", ")
        let callArguments = parameters.map { parameter -> String in
            let label = parameter.firstName.text
            let name = (parameter.secondName ?? parameter.firstName).text
            return label == "_" ? name : "\(label): \(name)"
        }.joined(separator: ", ")
        let continuation = context.makeUniqueName("continuation")
        return ["""
            func \(function.name)(\(raw: parameterList)) async -> \(raw: resultType) {
                await withCheckedContinuation { \(continuation) in
                    \(function.name)(\(raw: callArguments)) { result in
                        \(continuation).resume(returning: result)
                    }
                }
            }
            """]
    }
}

/// `@UserDefault("key") var value: Int = 0` → computed accessors backed by `UserDefaults.standard`.
public struct UserDefaultMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let type = binding.typeAnnotation?.type.trimmedDescription,
              case .argumentList(let arguments) = node.arguments,
              let key = arguments.first?.expression
        else { return [] }
        let fallback = binding.initializer?.value.trimmedDescription ?? "nil"
        return [
            "get { UserDefaults.standard.object(forKey: \(key)) as? \(raw: type) ?? \(raw: fallback) }",
            "set { UserDefaults.standard.set(newValue, forKey: \(key)) }",
        ]
    }
}

/// `#constants("a", "b")` → `let a = "a"` and `let b = "b"`.
public struct ConstantsMacro: DeclarationMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
        node.arguments.compactMap { argument in
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  let value = literal.segments.first?.as(StringSegmentSyntax.self)?.content.text
            else { return nil }
            return "let \(raw: value) = \(literal: value)"
        }
    }
}
