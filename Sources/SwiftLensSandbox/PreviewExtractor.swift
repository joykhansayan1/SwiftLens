import SwiftLensCore
import SwiftParser
import SwiftSyntax

/// Finds everything renderable in a snippet: `#Preview` blocks (with traits and `@Previewable` state),
/// `PreviewProvider`s and — as a fallback — `View` types that can be created with `init()`.
public enum PreviewExtractor {
    public static func extract(_ document: SourceDocument, includeViewTypesWhenNoPreviews: Bool = true) -> [PreviewEntry] {
        let visitor = Visitor(document: document)
        visitor.walk(document.tree)
        var entries = visitor.previews + visitor.providers
        if entries.isEmpty && includeViewTypesWhenNoPreviews {
            entries = visitor.viewTypes
        }
        for index in entries.indices { entries[index].id = index }
        return entries
    }

    /// The `#Preview` nodes (expression or declaration form) in a document, for blanking them out.
    public static func previewMacroNodes(in document: SourceDocument) -> [Syntax] {
        let visitor = Visitor(document: document)
        visitor.walk(document.tree)
        return visitor.previewNodes
    }

    static func isPreviewMacro(_ name: String) -> Bool { name == "Preview" }

    final class Visitor: SyntaxVisitor {
        let document: SourceDocument
        var previews: [PreviewEntry] = []
        var providers: [PreviewEntry] = []
        var viewTypes: [PreviewEntry] = []
        var previewNodes: [Syntax] = []

        init(document: SourceDocument) {
            self.document = document
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
            if isPreviewMacro(node.macroName.text) { record(node) }
            return .skipChildren
        }

        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            if isPreviewMacro(node.macroName.text) { record(node) }
            return .skipChildren
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            if inherited.contains(where: { $0 == "PreviewProvider" || $0 == "SwiftUI.PreviewProvider" }) {
                providers.append(PreviewEntry(
                    id: 0,
                    name: node.name.text.replacingOccurrences(of: "_Previews", with: ""),
                    kind: .previewProvider,
                    span: document.span(of: node),
                    traits: [],
                    previewableDeclarations: [],
                    body: "\(node.name.text).previews",
                    bodyLine: document.span(of: node).start.line,
                    typeName: node.name.text
                ))
            } else if inherited.contains(where: { $0 == "View" || $0 == "SwiftUI.View" }), isDefaultConstructible(node) {
                viewTypes.append(PreviewEntry(
                    id: 0,
                    name: node.name.text,
                    kind: .viewType,
                    span: document.span(of: node),
                    traits: [],
                    previewableDeclarations: [],
                    body: "\(node.name.text)()",
                    bodyLine: document.span(of: node).start.line,
                    typeName: node.name.text
                ))
            }
            return .visitChildren
        }

        private func record(_ node: some FreestandingMacroExpansionSyntax) {
            previewNodes.append(Syntax(node))
            var name: String?
            var traits: [PreviewTrait] = []
            var bodyClosure = node.trailingClosure
            var inTraits = false
            for argument in node.arguments {
                if let label = argument.label?.text {
                    inTraits = label == "traits"
                    if label == "body" { bodyClosure = argument.expression.as(ClosureExprSyntax.self) }
                    if inTraits { traits.append(PreviewExtractor.trait(from: argument.expression)) }
                } else if inTraits {
                    traits.append(PreviewExtractor.trait(from: argument.expression))
                } else if name == nil, let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                    name = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
                }
            }

            var previewables: [String] = []
            var statements: [String] = []
            var bodyLine = document.span(of: node).start.line
            var foundFirstStatement = false
            for item in bodyClosure?.statements ?? [] {
                if let variable = item.item.as(VariableDeclSyntax.self),
                   variable.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Previewable" }) {
                    previewables.append(PreviewExtractor.lowerPreviewable(variable))
                } else {
                    if !foundFirstStatement {
                        bodyLine = document.span(of: item).start.line
                        foundFirstStatement = true
                    }
                    statements.append(item.trimmedDescription)
                }
            }

            previews.append(PreviewEntry(
                id: 0,
                name: name ?? "Preview \(previews.count + 1)",
                kind: .previewMacro,
                span: document.span(of: node),
                traits: traits,
                previewableDeclarations: previewables,
                body: statements.joined(separator: "\n"),
                bodyLine: bodyLine,
                typeName: nil
            ))
        }

        /// A `View` struct can be previewed automatically if all stored properties have default values
        /// and it has no initializer that requires arguments.
        private func isDefaultConstructible(_ node: StructDeclSyntax) -> Bool {
            if node.genericParameterClause != nil { return false }
            var hasZeroArgumentInit = false
            var hasInit = false
            for member in node.memberBlock.members {
                if let initializer = member.decl.as(InitializerDeclSyntax.self) {
                    hasInit = true
                    if initializer.signature.parameterClause.parameters.allSatisfy({ $0.defaultValue != nil }) {
                        hasZeroArgumentInit = true
                    }
                }
                guard let variable = member.decl.as(VariableDeclSyntax.self),
                      !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
                else { continue }
                let attributeNames = variable.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
                if attributeNames.contains(where: { ["EnvironmentObject", "Binding", "ObservedObject"].contains($0) }) { return false }
                if attributeNames.contains(where: { ["Environment", "FocusState", "Namespace", "GestureState"].contains($0) }) { continue }
                for binding in variable.bindings where binding.accessorBlock == nil {
                    let optional = binding.typeAnnotation?.type.is(OptionalTypeSyntax.self) ?? false
                    if binding.initializer == nil && !(optional && variable.bindingSpecifier.tokenKind == .keyword(.var)) {
                        if !hasInit { return false }
                    }
                }
            }
            return !hasInit || hasZeroArgumentInit
        }
    }

    /// `@Previewable @State var x = 0` → `@State var x = 0`
    static func lowerPreviewable(_ variable: VariableDeclSyntax) -> String {
        var copy = variable
        copy.attributes = copy.attributes.filter {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription != "Previewable"
        }
        if let first = copy.attributes.first {
            var attributes = copy.attributes
            let index = attributes.startIndex
            attributes[index] = first.with(\.leadingTrivia, [])
            copy.attributes = attributes
        } else {
            copy.bindingSpecifier = copy.bindingSpecifier.with(\.leadingTrivia, [])
        }
        return copy.trimmedDescription
    }

    static func trait(from expression: ExprSyntax) -> PreviewTrait {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            switch member.declName.baseName.text {
            case "sizeThatFitsLayout": return .sizeThatFitsLayout
            case "defaultLayout": return .defaultLayout
            case "portrait": return .portrait
            case "portraitUpsideDown": return .portraitUpsideDown
            case "landscapeLeft": return .landscapeLeft
            case "landscapeRight": return .landscapeRight
            default: return .other(expression.trimmedDescription)
            }
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "fixedLayout" {
            func number(_ label: String) -> Double? {
                guard let argument = call.arguments.first(where: { $0.label?.text == label }) else { return nil }
                let text = argument.expression.trimmedDescription
                return Double(text)
            }
            if let width = number("width"), let height = number("height") {
                return .fixedLayout(width: width, height: height)
            }
        }
        return .other(expression.trimmedDescription)
    }
}
