import Foundation
import SwiftIDEUtils
import SwiftParser
import SwiftSyntax

/// A highlighted range, in both UTF-8 (swift-syntax) and UTF-16 (AppKit / NSString) units.
public struct HighlightToken: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case keyword, type, identifier, string, number, comment, docComment, attribute, `operator`, directive, label, placeholder, regex
    }

    public var kind: Kind
    public var utf8Offset: Int
    public var utf8Length: Int
    public var utf16Offset: Int
    public var utf16Length: Int
}

/// Syntax highlighting driven by swift-syntax's own classifier (the one SourceKit-LSP uses), so macros,
/// attributes and contextual keywords are coloured correctly.
public enum SyntaxHighlighter {
    public static func highlight(_ text: String) -> [HighlightToken] {
        highlight(Parser.parse(source: text), text: text)
    }

    public static func highlight(_ tree: SourceFileSyntax, text: String) -> [HighlightToken] {
        let utf8 = Array(text.utf8)
        // Prefix sums mapping UTF-8 offsets to UTF-16 offsets.
        var utf16At = [Int](repeating: 0, count: utf8.count + 1)
        var utf16 = 0
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            let width: Int
            if byte < 0x80 { width = 1 } else if byte >> 5 == 0b110 { width = 2 } else if byte >> 4 == 0b1110 { width = 3 } else { width = 4 }
            for k in 0..<width where index + k <= utf8.count { utf16At[min(index + k, utf8.count)] = utf16 }
            utf16 += width == 4 ? 2 : 1
            index += width
        }
        utf16At[utf8.count] = utf16

        var tokens: [HighlightToken] = []
        for classified in tree.classifications {
            guard let kind = map(classified.kind) else { continue }
            let start = min(classified.offset, utf8.count)
            let end = min(classified.endOffset, utf8.count)
            guard end > start else { continue }
            tokens.append(HighlightToken(
                kind: kind,
                utf8Offset: start,
                utf8Length: end - start,
                utf16Offset: utf16At[start],
                utf16Length: utf16At[end] - utf16At[start]
            ))
        }
        return tokens
    }

    static func map(_ classification: SyntaxClassification) -> HighlightToken.Kind? {
        switch classification {
        case .keyword: .keyword
        case .type: .type
        case .identifier, .dollarIdentifier: nil
        case .stringLiteral: .string
        case .integerLiteral, .floatLiteral: .number
        case .lineComment, .blockComment: .comment
        case .docLineComment, .docBlockComment: .docComment
        case .attribute: .attribute
        case .operator: .operator
        case .ifConfigDirective: .directive
        case .argumentLabel: .label
        case .editorPlaceholder: .placeholder
        case .regexLiteral: .regex
        case .none: nil
        @unknown default: nil
        }
    }
}
