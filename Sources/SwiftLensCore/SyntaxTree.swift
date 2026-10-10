@_spi(RawSyntax) import SwiftSyntax

/// A serializable snapshot of a swift-syntax tree, designed for visualisation.
///
/// Unlike web-based AST explorers, the tree is produced by the very swift-syntax version that SwiftLens links,
/// so what you see is exactly what a macro implementation receives. Every node also carries an
/// ``accessPath`` — a ready-to-paste Swift expression that navigates from the root to the node — which is the
/// thing macro authors usually have to work out by trial and error.
public struct SyntaxTreeNode: Codable, Hashable, Identifiable, Sendable {
    public enum Category: String, Codable, Sendable {
        case declaration, expression, statement, type, pattern, token, collection, other
    }

    public struct Token: Codable, Hashable, Sendable {
        public var text: String
        public var kind: String
        public var leadingTrivia: String
        public var trailingTrivia: String
        public var presence: String
    }

    /// Pre-order index; unique within one tree.
    public var id: Int
    /// The concrete swift-syntax type name, e.g. `StructDeclSyntax`.
    public var kind: String
    public var category: Category
    /// The property name under which this node is stored in its parent (`memberBlock`, `bindings`, ...).
    public var childName: String?
    /// Index inside the parent when the parent is a syntax collection.
    public var indexInParent: Int?
    /// Swift expression that reaches this node from the root (see ``SyntaxAccessPath``).
    public var accessPath: String
    /// The source range without trivia.
    public var span: SourceSpan
    public var token: Token?
    public var isMissing: Bool
    public var hasError: Bool
    /// A short human readable hint, e.g. the name of a declaration.
    public var summary: String?
    public var children: [SyntaxTreeNode]

    /// Total number of nodes in this subtree (including itself).
    public var subtreeCount: Int { 1 + children.reduce(0) { $0 + $1.subtreeCount } }

    /// Depth-first search for the node with the given id.
    public func find(id: Int) -> SyntaxTreeNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id: id) { return found }
        }
        return nil
    }

    /// Returns the path of nodes from this node down to the innermost node whose span contains `offset`.
    public func path(toOffset offset: Int) -> [SyntaxTreeNode] {
        guard span.contains(offset: offset) || (span.length == 0 && span.start.offset == offset) else { return [] }
        for child in children {
            let sub = child.path(toOffset: offset)
            if !sub.isEmpty { return [self] + sub }
        }
        return [self]
    }

    /// All nodes in pre-order.
    public func flattened() -> [SyntaxTreeNode] {
        var result: [SyntaxTreeNode] = [self]
        for child in children { result += child.flattened() }
        return result
    }
}

/// Options controlling how much of the tree is captured.
public struct SyntaxTreeOptions: Sendable {
    /// Include token leaves.
    public var includeTokens: Bool = true
    /// Include tokens that the parser synthesised as missing.
    public var includeMissing: Bool = true
    /// Stop descending below this depth (root = 0). `nil` means unlimited.
    public var maxDepth: Int? = nil
    /// Hard cap on number of nodes to protect UIs from gigantic files.
    public var maxNodes: Int = 200_000

    public init(includeTokens: Bool = true, includeMissing: Bool = true, maxDepth: Int? = nil, maxNodes: Int = 200_000) {
        self.includeTokens = includeTokens
        self.includeMissing = includeMissing
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }
}

public enum SyntaxTreeBuilder {
    public static func build(_ document: SourceDocument, options: SyntaxTreeOptions = .init()) -> SyntaxTreeNode {
        build(Syntax(document.tree), in: document, options: options)
    }

    public static func build(_ root: Syntax, in document: SourceDocument, options: SyntaxTreeOptions = .init()) -> SyntaxTreeNode {
        var counter = 0
        return makeNode(root, path: SyntaxAccessPath(rootName: rootName(for: root)), depth: 0, document: document, options: options, counter: &counter)
    }

    private static func rootName(for node: Syntax) -> String {
        node.is(SourceFileSyntax.self) ? "sourceFile" : "node"
    }

    private static func makeNode(
        _ node: Syntax,
        path: SyntaxAccessPath,
        depth: Int,
        document: SourceDocument,
        options: SyntaxTreeOptions,
        counter: inout Int
    ) -> SyntaxTreeNode {
        let id = counter
        counter += 1

        var tokenInfo: SyntaxTreeNode.Token?
        if let token = node.as(TokenSyntax.self) {
            tokenInfo = .init(
                text: token.text,
                kind: describe(token.tokenKind),
                leadingTrivia: describe(token.leadingTrivia),
                trailingTrivia: describe(token.trailingTrivia),
                presence: token.presence == .present ? "present" : "missing"
            )
        }

        var children: [SyntaxTreeNode] = []
        let descend = options.maxDepth.map { depth < $0 } ?? true
        if descend {
            let isCollection = node.kind.isSyntaxCollection
            var index = 0
            for child in node.children(viewMode: options.includeMissing ? .all : .sourceAccurate) {
                defer { index += 1 }
                if counter >= options.maxNodes { break }
                if !options.includeTokens && child.is(TokenSyntax.self) { continue }
                let childPath = isCollection ? path.element(index, of: child) : path.child(child)
                var built = makeNode(child, path: childPath, depth: depth + 1, document: document, options: options, counter: &counter)
                if isCollection { built.indexInParent = index }
                children.append(built)
            }
        }

        return SyntaxTreeNode(
            id: id,
            kind: kindName(of: node),
            category: category(of: node),
            childName: node.keyPathInParent.flatMap { SwiftSyntax.childName($0) },
            indexInParent: nil,
            accessPath: path.rendered,
            span: document.span(of: node),
            token: tokenInfo,
            isMissing: isMissing(node),
            hasError: node.hasError,
            summary: summary(of: node),
            children: children
        )
    }

    static func isMissing(_ node: Syntax) -> Bool {
        if let token = node.as(TokenSyntax.self) { return token.presence == .missing }
        let tokens = node.tokens(viewMode: .all)
        return tokens.first(where: { _ in true }) != nil && tokens.allSatisfy { $0.presence == .missing }
    }

    public static func kindName(of node: Syntax) -> String {
        "\(node.syntaxNodeType)"
    }

    public static func category(of node: Syntax) -> SyntaxTreeNode.Category {
        if node.is(TokenSyntax.self) { return .token }
        if node.kind.isSyntaxCollection { return .collection }
        if node.is(DeclSyntax.self) { return .declaration }
        if node.is(ExprSyntax.self) { return .expression }
        if node.is(StmtSyntax.self) { return .statement }
        if node.is(TypeSyntax.self) { return .type }
        if node.is(PatternSyntax.self) { return .pattern }
        return .other
    }

    public static func summary(of node: Syntax) -> String? {
        if let named = node.asProtocol(NamedDeclSyntax.self) { return named.name.text }
        if let variable = node.as(VariableDeclSyntax.self) {
            return variable.bindings.map { $0.pattern.trimmedDescription }.joined(separator: ", ")
        }
        if let function = node.as(FunctionCallExprSyntax.self) { return function.calledExpression.trimmedDescription }
        if let macro = node.as(MacroExpansionExprSyntax.self) { return "#" + macro.macroName.text }
        if let macro = node.as(MacroExpansionDeclSyntax.self) { return "#" + macro.macroName.text }
        if let attribute = node.as(AttributeSyntax.self) { return "@" + attribute.attributeName.trimmedDescription }
        if let ext = node.as(ExtensionDeclSyntax.self) { return ext.extendedType.trimmedDescription }
        if let initializer = node.as(InitializerDeclSyntax.self) { return "init" + initializer.signature.parameterClause.trimmedDescription }
        return nil
    }

    static func describe(_ kind: TokenKind) -> String {
        let raw = String(describing: kind)
        return raw
            .replacingOccurrences(of: "SwiftSyntax.Keyword.", with: ".")
            .replacingOccurrences(of: "SwiftSyntax.", with: "")
    }

    static func describe(_ trivia: Trivia) -> String {
        trivia.pieces.map { piece -> String in
            switch piece {
            case .spaces(let n): return n == 1 ? "space" : "spaces(\(n))"
            case .tabs(let n): return "tabs(\(n))"
            case .newlines(let n): return n == 1 ? "newline" : "newlines(\(n))"
            case .carriageReturns(let n): return "carriageReturns(\(n))"
            case .carriageReturnLineFeeds(let n): return "crlf(\(n))"
            case .lineComment(let text): return "lineComment(\(text.debugDescription))"
            case .blockComment(let text): return "blockComment(\(text.debugDescription))"
            case .docLineComment(let text): return "docLineComment(\(text.debugDescription))"
            case .docBlockComment(let text): return "docBlockComment(\(text.debugDescription))"
            default: return String(describing: piece)
            }
        }.joined(separator: ", ")
    }
}

/// Builds a Swift expression that navigates from a root syntax node to a descendant, inserting
/// `.as(Concrete.self)` casts where swift-syntax exposes a type-erased base (`DeclSyntax`, `ExprSyntax`, ...).
///
/// Example: `sourceFile.statements.first?.item.as(StructDeclSyntax.self)?.memberBlock.members.first?.decl`
public struct SyntaxAccessPath: Hashable, Sendable {
    private var components: [String]
    private var isOptional: Bool

    public init(rootName: String) {
        components = [rootName]
        isOptional = false
    }

    public var rendered: String { components.joined() }

    private var dot: String { isOptional ? "?." : "." }

    private static let erasedBases: Set<String> = [
        "DeclSyntax", "ExprSyntax", "StmtSyntax", "TypeSyntax", "PatternSyntax", "Syntax",
    ]

    func child(_ node: Syntax) -> SyntaxAccessPath {
        var copy = self
        guard let keyPath = node.keyPathInParent, let name = SwiftSyntax.childName(keyPath) else {
            copy.components.append("\(dot)children(viewMode: .sourceAccurate)")
            return copy
        }
        copy.components.append("\(dot)\(name)")
        let valueType = String(reflecting: type(of: keyPath).valueType)
            .replacingOccurrences(of: "Swift.", with: "")
            .replacingOccurrences(of: "SwiftSyntax.", with: "")
        let optional = valueType.hasPrefix("Optional<")
        let base = optional ? String(valueType.dropFirst("Optional<".count).dropLast()) : valueType
        if optional { copy.isOptional = true }
        copy.appendCastIfNeeded(declaredType: base, node: node)
        return copy
    }

    func element(_ index: Int, of node: Syntax) -> SyntaxAccessPath {
        var copy = self
        copy.components.append(index == 0 ? "\(dot)first" : "\(dot)dropFirst(\(index)).first")
        copy.isOptional = true
        // A few collections store "choice" elements (e.g. `@attr` or `#if` inside an attribute list).
        let choiceCollections = ["AttributeListSyntax", "SwitchCaseListSyntax", "PrecedenceGroupAttributeListSyntax"]
        if let parent = node.parent, choiceCollections.contains("\(parent.syntaxNodeType)") {
            copy.components.append("\(copy.dot)as(\(node.syntaxNodeType).self)")
        }
        return copy
    }

    private mutating func appendCastIfNeeded(declaredType: String, node: Syntax) {
        let concrete = "\(node.syntaxNodeType)"
        let needsCast: Bool
        do {
            // Either a type-erased base (`DeclSyntax`) or a child-choice enum (`CodeBlockItemSyntax.Item`).
            let isChoice = declaredType.contains(".")
            let erased = Self.erasedBases.contains(declaredType)
            needsCast = (erased || isChoice) && declaredType != concrete
        }
        if needsCast {
            components.append("\(dot)as(\(concrete).self)")
            isOptional = true
        }
    }
}

extension SyntaxTreeNode {
    /// Renders the tree using box-drawing characters, for terminals and plain-text exports.
    public func asciiTree(showSpans: Bool = true, showAccessPaths: Bool = false) -> String {
        var lines: [String] = []
        render(prefix: "", childPrefix: "", into: &lines, showSpans: showSpans, showAccessPaths: showAccessPaths)
        return lines.joined(separator: "\n")
    }

    private func render(prefix: String, childPrefix: String, into lines: inout [String], showSpans: Bool, showAccessPaths: Bool) {
        var label = ""
        if let childName { label += "\(childName): " }
        if let indexInParent { label += "[\(indexInParent)] " }
        if let token {
            label += "\(token.kind) \(token.text.debugDescription)"
            if isMissing { label += " (missing)" }
        } else {
            label += kind
            if let summary { label += " ‹\(summary)›" }
        }
        if hasError && token == nil { label += " ⚠︎" }
        if showSpans { label += "  \(span)" }
        if showAccessPaths { label += "  ⇢ \(accessPath)" }
        lines.append(prefix + label)
        for (offset, child) in children.enumerated() {
            let last = offset == children.count - 1
            child.render(
                prefix: childPrefix + (last ? "└─ " : "├─ "),
                childPrefix: childPrefix + (last ? "   " : "│  "),
                into: &lines,
                showSpans: showSpans,
                showAccessPaths: showAccessPaths
            )
        }
    }
}
