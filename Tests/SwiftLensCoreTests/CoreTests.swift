@testable import SwiftLensCore
import XCTest

final class SyntaxTreeTests: XCTestCase {
    let source = """
    struct Counter {
        var count = 0
    }
    """

    func testBuildsTreeWithSpansAndSummaries() {
        let document = SourceDocument(text: source)
        let tree = SyntaxTreeBuilder.build(document)
        XCTAssertEqual(tree.kind, "SourceFileSyntax")
        let nodes = tree.flattened()
        let structNode = try? XCTUnwrap(nodes.first { $0.kind == "StructDeclSyntax" })
        XCTAssertEqual(structNode?.summary, "Counter")
        XCTAssertEqual(structNode?.span.start.line, 1)
        XCTAssertEqual(structNode?.span.end.line, 3)
        let token = nodes.first { $0.token?.text == "count" }
        XCTAssertEqual(token?.category, .token)
        XCTAssertEqual(token?.span.start, SourcePosition(line: 2, column: 9, offset: 25))
        XCTAssertEqual(Set(nodes.map(\.id)).count, nodes.count, "ids are unique")
    }

    func testAccessPathsInsertCasts() {
        let document = SourceDocument(text: source)
        let tree = SyntaxTreeBuilder.build(document)
        let variable = tree.flattened().first { $0.kind == "VariableDeclSyntax" }
        XCTAssertEqual(
            variable?.accessPath,
            "sourceFile.statements.first?.item.as(StructDeclSyntax.self)?.memberBlock.members.first?.decl.as(VariableDeclSyntax.self)"
        )
        let identifier = tree.flattened().first { $0.kind == "IdentifierPatternSyntax" }
        XCTAssertEqual(
            identifier?.accessPath,
            "sourceFile.statements.first?.item.as(StructDeclSyntax.self)?.memberBlock.members.first?.decl.as(VariableDeclSyntax.self)?.bindings.first?.pattern.as(IdentifierPatternSyntax.self)"
        )
    }

    func testPathToOffsetFindsInnermostNode() {
        let document = SourceDocument(text: source)
        let tree = SyntaxTreeBuilder.build(document)
        let offset = (source as NSString).range(of: "count").location
        let path = tree.path(toOffset: offset)
        XCTAssertEqual(path.last?.token?.text, "count")
        XCTAssertEqual(document.innermostNode(atOffset: offset)?.trimmedDescription, "count")
    }

    func testOptionsLimitTree() {
        let document = SourceDocument(text: source)
        let shallow = SyntaxTreeBuilder.build(document, options: .init(maxDepth: 1))
        XCTAssertTrue(shallow.children.allSatisfy { $0.children.isEmpty })
        let noTokens = SyntaxTreeBuilder.build(document, options: .init(includeTokens: false))
        XCTAssertFalse(noTokens.flattened().contains { $0.category == .token })
    }

    func testAsciiTreeRendering() {
        let ascii = SyntaxTreeBuilder.build(SourceDocument(text: "let x = 1")).asciiTree(showSpans: false)
        XCTAssertTrue(ascii.hasPrefix("SourceFileSyntax"))
        XCTAssertTrue(ascii.contains("└─ "))
        XCTAssertTrue(ascii.contains(#"keyword(.let) "let""#), ascii)
    }

    func testParserDiagnostics() {
        let document = SourceDocument(text: "let x = ")
        XCTAssertEqual(document.parserDiagnostics.first?.severity, .error)
        XCTAssertTrue(SyntaxTreeBuilder.build(document).flattened().contains { $0.isMissing })
    }
}

final class MacroUsageScannerTests: XCTestCase {
    func testFindsFreestandingAndAttachedMacros() {
        let document = SourceDocument(text: """
        @Observable
        final class Model {
            @ObservationIgnored var cache = 0
            @available(*, deprecated) var old = 1
            @State var state = 0
        }
        let x = #stringify(1 + 2)
        #Preview("Card") { Text("Hi") }
        """)
        let usages = MacroUsageScanner.scan(document)
        XCTAssertEqual(usages.map(\.spelling), ["@Observable", "@ObservationIgnored", "@State", "#stringify", "#Preview"])
        XCTAssertEqual(usages[0].attachedTo?.name, "Model")
        XCTAssertEqual(usages[3].kind, .freestandingExpression)
        XCTAssertEqual(usages[4].kind, .freestandingDeclaration)
        XCTAssertEqual(usages[4].argumentLabels, [nil])
        XCTAssertTrue(usages[4].hasTrailingClosure)
    }
}

final class TextDiffTests: XCTestCase {
    func testUnifiedDiff() {
        let old = "a\nb\nc\nd\n"
        let new = "a\nb\nX\nc\nd\n"
        let diff = TextDiff.unified(from: old, to: new)
        XCTAssertEqual(diff, """
        --- a/original.swift
        +++ b/expanded.swift
        @@ -1,4 +1,5 @@
         a
         b
        +X
         c
         d

        """)
    }

    func testIdenticalTextsProduceNoDiff() {
        XCTAssertEqual(TextDiff.unified(from: "same\n", to: "same\n"), "")
    }

    func testLineNumbersAndStats() {
        let lines = TextDiff.lines(from: "1\n2\n3", to: "1\n3\n4")
        XCTAssertEqual(lines.map(\.operation), [.equal, .delete, .equal, .insert])
        XCTAssertEqual(lines.last?.newLine, 3)
        XCTAssertEqual(TextDiff.stats(lines).insertions, 1)
        XCTAssertEqual(TextDiff.stats(lines).deletions, 1)
    }

    func testRandomizedDiffsReconstructTarget() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...12, using: &generator)).map { _ in String(Int.random(in: 0...4, using: &generator)) }
            let b = (0..<Int.random(in: 0...12, using: &generator)).map { _ in String(Int.random(in: 0...4, using: &generator)) }
            let script = TextDiff.lines(from: a.joined(separator: "\n"), to: b.joined(separator: "\n"))
            XCTAssertEqual(script.filter { $0.operation != .delete }.map(\.text), b)
            XCTAssertEqual(script.filter { $0.operation != .insert }.map(\.text), a)
        }
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    func testClassifiesTokens() {
        let text = "// hi\n@Observable final class A { let s = \"é\"; let n = 1 }"
        let tokens = SyntaxHighlighter.highlight(text)
        func kinds(_ substring: String) -> [HighlightToken.Kind] {
            let range = (text as NSString).range(of: substring)
            return tokens.filter { $0.utf16Offset == range.location && $0.utf16Length == range.length }.map(\.kind)
        }
        XCTAssertEqual(kinds("// hi"), [.comment])
        XCTAssertEqual(kinds("@Observable").isEmpty && kinds("Observable").isEmpty, false)
        XCTAssertEqual(kinds("class"), [.keyword])
        XCTAssertEqual(kinds("\"é\""), [.string])
        XCTAssertEqual(kinds("1"), [.number])
        // UTF-16 offsets account for the 2-byte "é".
        let number = tokens.first { $0.kind == .number }!
        XCTAssertEqual(number.utf8Offset - number.utf16Offset, 1)
    }
}
