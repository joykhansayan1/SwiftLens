import SwiftLensCore
import SwiftParser
import SwiftSyntax

/// Source transformations offered by the Xcode Source Editor extension. Pure syntax, so they run inside the
/// sandboxed extension without a compiler.
public enum PreviewMigrator {
    /// Rewrites every `struct X_Previews: PreviewProvider { static var previews: some View { ... } }` into
    /// `#Preview("X") { ... }`. Returns `nil` when there is nothing to convert.
    public static func convertPreviewProvidersToMacros(_ source: String) -> String? {
        let tree = Parser.parse(source: source)
        let rewriter = ProviderRewriter(viewMode: .sourceAccurate)
        let rewritten = rewriter.rewrite(tree)
        return rewriter.didChange ? rewritten.description : nil
    }

    /// Wraps a view expression (e.g. the current selection) into a `#Preview` block.
    public static func wrapInPreview(_ expression: String, name: String? = nil, indentation: String = "    ") -> String {
        let body = expression
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : indentation + $0 }
            .joined(separator: "\n")
        let title = name.map { "(\"\($0)\")" } ?? ""
        return "#Preview\(title) {\n\(body)\n}\n"
    }

    /// Removes the common indentation of `text` (ignoring blank lines) and indents every line by `prefix`.
    static func reindent(_ text: String, by prefix: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        let indentation = lines.filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
            .min() ?? 0
        return lines.map { line in
            line.allSatisfy(\.isWhitespace) ? "" : prefix + line.dropFirst(indentation)
        }.joined(separator: "\n")
    }

    final class ProviderRewriter: SyntaxRewriter {
        var didChange = false

        override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
            var items: [CodeBlockItemSyntax] = []
            for item in node {
                guard let structDecl = item.item.as(StructDeclSyntax.self),
                      let replacement = Self.previewMacro(for: structDecl)
                else {
                    items.append(item)
                    continue
                }
                didChange = true
                var newItem = item
                newItem.item = .decl(DeclSyntax(replacement))
                items.append(newItem)
            }
            return CodeBlockItemListSyntax(items)
        }

        static func previewMacro(for node: StructDeclSyntax) -> MacroExpansionDeclSyntax? {
            let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            guard inherited.contains(where: { $0 == "PreviewProvider" || $0 == "SwiftUI.PreviewProvider" }) else { return nil }
            let previews = node.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }.first {
                $0.bindings.first?.pattern.trimmedDescription == "previews"
            }
            guard let binding = previews?.bindings.first, let accessor = binding.accessorBlock else { return nil }
            let statements: CodeBlockItemListSyntax
            switch accessor.accessors {
            case .getter(let items):
                statements = items
            case .accessors(let list):
                guard let getter = list.first(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) }), let body = getter.body else { return nil }
                statements = body.statements
            }
            let name = node.name.text.replacingOccurrences(of: "_Previews", with: "").replacingOccurrences(of: "_Preview", with: "")
            let body = reindent(statements.description, by: "    ")
            let text = "#Preview(\"\(name)\") {\n\(body)\n}"
            var parser = Parser(text)
            guard var macro = DeclSyntax.parse(from: &parser).as(MacroExpansionDeclSyntax.self) else { return nil }
            macro.leadingTrivia = node.leadingTrivia
            macro.trailingTrivia = node.trailingTrivia
            return macro
        }
    }
}
