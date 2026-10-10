import SwiftSyntax

/// A syntactic occurrence of something that may be a macro: `#name(...)` or a custom `@Name` attribute.
///
/// Whether an `@Name` attribute really is a macro (rather than a property wrapper, result builder or global actor)
/// can only be decided with knowledge of the macro declarations in scope — the macro engine's registry does that.
public struct MacroUsage: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `#name(...)` in expression position.
        case freestandingExpression
        /// `#name(...)` in declaration / statement position.
        case freestandingDeclaration
        /// `@Name` attached to a declaration.
        case attached
    }

    public struct AttachedDeclaration: Codable, Hashable, Sendable {
        public var kind: String
        public var name: String?
        public var span: SourceSpan
    }

    public var id: Int
    public var name: String
    public var kind: Kind
    public var span: SourceSpan
    /// The argument text, if any (without the surrounding parentheses / trailing closures).
    public var arguments: String?
    public var argumentLabels: [String?]
    public var hasTrailingClosure: Bool
    public var attachedTo: AttachedDeclaration?
    /// Nesting depth: a macro used inside the arguments or attached declaration of another macro has depth > 0.
    public var depth: Int

    /// `#name` or `@Name`.
    public var spelling: String { (kind == .attached ? "@" : "#") + name }
}

public enum MacroUsageScanner {
    /// Attributes that are part of the language and can never be macros.
    public static let builtinAttributes: Set<String> = [
        "available", "objc", "objcMembers", "nonobjc", "discardableResult", "escaping", "autoclosure",
        "inlinable", "usableFromInline", "frozen", "main", "testable", "IBAction", "IBOutlet", "IBDesignable",
        "IBInspectable", "IBSegueAction", "NSCopying", "NSManaged", "GKInspectable", "dynamicMemberLookup",
        "dynamicCallable", "propertyWrapper", "resultBuilder", "requires_stored_property_inits", "warn_unqualified_access",
        "Sendable", "unchecked", "preconcurrency", "retroactive", "backDeployed", "convention", "differentiable",
        "noDerivative", "derivative", "transpose", "_spi", "_exported", "_implementationOnly", "_disfavoredOverload",
        "_silgen_name", "_cdecl", "_dynamicReplacement", "_specialize", "_effects", "_alwaysEmitIntoClient",
        "_transparent", "_semantics", "_optimize", "_originallyDefinedIn", "_documentation", "_spi_available",
        "_nonSendable", "_unsafeInheritExecutor", "_inheritActorContext", "_implicitSelfCapture", "_marker",
        "_objcRuntimeName", "_staticInitializeObjCMetadata", "_typeEraser", "_unavailableFromAsync", "_noImplicitCopy",
        "attached", "freestanding", "storageRestrictions", "MainActor", "globalActor", "isolated", "_local",
        "UIApplicationMain", "NSApplicationMain", "UIApplicationDelegateAdaptor", "NSApplicationDelegateAdaptor",
        "unknown", "Test", "Suite",
    ]

    /// Well-known property wrappers / result builders that look like attached macros but are not.
    public static let wellKnownNonMacroAttributes: Set<String> = [
        "State", "Binding", "ObservedObject", "StateObject", "EnvironmentObject", "Environment", "Published",
        "AppStorage", "SceneStorage", "FocusState", "FocusedValue", "FocusedBinding", "GestureState", "Namespace",
        "ScaledMetric", "FetchRequest", "SectionedFetchRequest", "Query", "Bindable", "ViewBuilder", "SceneBuilder",
        "ToolbarContentBuilder", "CommandsBuilder", "ResultBuilder", "UIApplicationDelegateAdaptor", "AccessibilityRotorContentBuilder",
    ]

    public static func scan(_ document: SourceDocument) -> [MacroUsage] {
        let visitor = Visitor(document: document)
        visitor.walk(document.tree)
        return visitor.usages
    }

    final class Visitor: SyntaxVisitor {
        let document: SourceDocument
        var usages: [MacroUsage] = []
        private var depth = 0

        init(document: SourceDocument) {
            self.document = document
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            // A `#macro` that forms a whole statement (e.g. a top-level `#Preview { }`) is parsed as an expression
            // but may well be a declaration macro.
            let statementLevel = node.parent?.is(CodeBlockItemSyntax.self) ?? false
            record(node, kind: statementLevel ? .freestandingDeclaration : .freestandingExpression)
            return .visitChildren
        }

        override func visitPost(_ node: MacroExpansionExprSyntax) { depth -= 1 }

        override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
            record(node, kind: .freestandingDeclaration)
            return .visitChildren
        }

        override func visitPost(_ node: MacroExpansionDeclSyntax) { depth -= 1 }

        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            let name = node.attributeName.trimmedDescription
            let simpleName = name.split(separator: ".").last.map(String.init) ?? name
            guard !MacroUsageScanner.builtinAttributes.contains(simpleName) else { return .skipChildren }

            var attached: MacroUsage.AttachedDeclaration?
            // AttributeSyntax -> AttributeListSyntax -> Decl
            if let decl = node.parent?.parent, decl.is(DeclSyntax.self) {
                attached = .init(
                    kind: "\(decl.syntaxNodeType)",
                    name: SyntaxTreeBuilder.summary(of: decl),
                    span: document.span(of: decl)
                )
            }
            var labels: [String?] = []
            var argumentText: String?
            if case .argumentList(let list) = node.arguments {
                labels = list.map { $0.label?.text }
                argumentText = list.trimmedDescription
            } else if let arguments = node.arguments {
                argumentText = arguments.trimmedDescription
            }
            usages.append(MacroUsage(
                id: usages.count,
                name: simpleName,
                kind: .attached,
                span: document.span(of: node),
                arguments: argumentText,
                argumentLabels: labels,
                hasTrailingClosure: false,
                attachedTo: attached,
                depth: depth
            ))
            return .visitChildren
        }

        private func record(_ node: some FreestandingMacroExpansionSyntax, kind: MacroUsage.Kind) {
            usages.append(MacroUsage(
                id: usages.count,
                name: node.macroName.text,
                kind: kind,
                span: document.span(of: node),
                arguments: node.arguments.isEmpty ? nil : node.arguments.trimmedDescription,
                argumentLabels: node.arguments.map { $0.label?.text },
                hasTrailingClosure: node.trailingClosure != nil,
                attachedTo: nil,
                depth: depth
            ))
            depth += 1
        }
    }
}
