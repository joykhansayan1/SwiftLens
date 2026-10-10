import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// A 1-based line/column position plus the UTF-8 offset it corresponds to.
public struct SourcePosition: Codable, Hashable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    public var offset: Int

    public init(line: Int, column: Int, offset: Int) {
        self.line = line
        self.column = column
        self.offset = offset
    }

    public var description: String { "\(line):\(column)" }
}

/// A half-open source range.
public struct SourceSpan: Codable, Hashable, Sendable, CustomStringConvertible {
    public var start: SourcePosition
    public var end: SourcePosition

    public init(start: SourcePosition, end: SourcePosition) {
        self.start = start
        self.end = end
    }

    public func contains(offset: Int) -> Bool { offset >= start.offset && offset < end.offset }
    public var length: Int { end.offset - start.offset }
    public var description: String { "\(start)-\(end)" }
}

/// Severity shared by parser diagnostics, macro diagnostics and compiler diagnostics.
public enum LensSeverity: String, Codable, Sendable, Comparable {
    case note, remark, warning, error

    private var rank: Int {
        switch self {
        case .note: 0
        case .remark: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: LensSeverity, rhs: LensSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// A textual edit suggested by a diagnostic.
public struct LensFixIt: Codable, Hashable, Sendable {
    public struct Edit: Codable, Hashable, Sendable {
        public var span: SourceSpan
        public var replacement: String

        public init(span: SourceSpan, replacement: String) {
            self.span = span
            self.replacement = replacement
        }
    }

    public var message: String
    public var edits: [Edit]

    public init(message: String, edits: [Edit]) {
        self.message = message
        self.edits = edits
    }
}

/// A diagnostic with resolved positions, independent of where it came from.
public struct LensDiagnostic: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Origin: String, Codable, Sendable {
        case parser
        case macro
        case compiler
        case sandbox
    }

    public var severity: LensSeverity
    public var message: String
    /// `nil` when the diagnostic points into generated code that has no position in the original file.
    public var position: SourcePosition?
    public var highlights: [SourceSpan]
    public var notes: [String]
    public var fixIts: [LensFixIt]
    public var origin: Origin
    /// For macro diagnostics: the macro that produced the diagnostic.
    public var macroName: String?

    public init(
        severity: LensSeverity,
        message: String,
        position: SourcePosition?,
        highlights: [SourceSpan] = [],
        notes: [String] = [],
        fixIts: [LensFixIt] = [],
        origin: Origin,
        macroName: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.position = position
        self.highlights = highlights
        self.notes = notes
        self.fixIts = fixIts
        self.origin = origin
        self.macroName = macroName
    }

    public var description: String {
        let location = position.map { "\($0.line):\($0.column): " } ?? ""
        let macro = macroName.map { " [\($0)]" } ?? ""
        return "\(location)\(severity.rawValue): \(message)\(macro)"
    }
}

/// A parsed Swift source buffer with helpers for converting between offsets and line/column positions.
public final class SourceDocument {
    public let fileName: String
    public let text: String
    public let tree: SourceFileSyntax
    public let converter: SourceLocationConverter

    public init(text: String, fileName: String = "Snippet.swift") {
        self.fileName = fileName
        self.text = text
        self.tree = Parser.parse(source: text)
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
    }

    public convenience init(contentsOf path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        self.init(text: text, fileName: path)
    }

    public func position(of absolute: AbsolutePosition) -> SourcePosition {
        let location = converter.location(for: absolute)
        return SourcePosition(line: location.line, column: location.column, offset: location.offset)
    }

    public func position(atOffset offset: Int) -> SourcePosition {
        position(of: AbsolutePosition(utf8Offset: max(0, min(offset, tree.endPosition.utf8Offset))))
    }

    /// The span of `node`, excluding leading and trailing trivia.
    public func span(of node: some SyntaxProtocol) -> SourceSpan {
        SourceSpan(
            start: position(of: node.positionAfterSkippingLeadingTrivia),
            end: position(of: node.endPositionBeforeTrailingTrivia)
        )
    }

    /// The span of `node`, including trivia.
    public func fullSpan(of node: some SyntaxProtocol) -> SourceSpan {
        SourceSpan(start: position(of: node.position), end: position(of: node.endPosition))
    }

    /// Syntax errors reported by the parser.
    public lazy var parserDiagnostics: [LensDiagnostic] = {
        ParseDiagnosticsGenerator.diagnostics(for: tree).map { diagnostic in
            LensDiagnostic(
                severity: LensSeverity(diagnostic.diagMessage.severity),
                message: diagnostic.message,
                position: position(of: diagnostic.position),
                highlights: diagnostic.highlights.map { span(of: $0) },
                notes: diagnostic.notes.map(\.message),
                fixIts: diagnostic.fixIts.map { fixIt in
                    LensFixIt(message: fixIt.message.message, edits: fixIt.edits.map { edit in
                        LensFixIt.Edit(
                            span: SourceSpan(
                                start: position(of: edit.range.lowerBound),
                                end: position(of: edit.range.upperBound)
                            ),
                            replacement: edit.replacement
                        )
                    })
                },
                origin: .parser
            )
        }
    }()

    /// Returns the innermost syntax node whose (trivia-free) range contains `offset`.
    public func innermostNode(atOffset offset: Int) -> Syntax? {
        guard offset >= 0, offset <= tree.endPosition.utf8Offset else { return nil }
        var current = Syntax(tree)
        outer: while true {
            for child in current.children(viewMode: .sourceAccurate) {
                let start = child.positionAfterSkippingLeadingTrivia.utf8Offset
                let end = child.endPositionBeforeTrailingTrivia.utf8Offset
                if offset >= start && offset < end {
                    current = child
                    continue outer
                }
            }
            return current
        }
    }
}

extension LensSeverity {
    public init(_ severity: DiagnosticSeverity) {
        switch severity {
        case .error: self = .error
        case .warning: self = .warning
        case .note: self = .note
        case .remark: self = .remark
        @unknown default: self = .note
        }
    }
}
