import AppKit
import Foundation
import SwiftLensSandbox
import XcodeKit

final class SourceEditorCommand: NSObject, XCSourceEditorCommand {
    enum Failure: LocalizedError {
        case nothingToConvert
        case emptySelection
        case couldNotOpenApp

        var errorDescription: String? {
            switch self {
            case .nothingToConvert: "No PreviewProvider found in this file."
            case .emptySelection: "Select the view expression to preview first."
            case .couldNotOpenApp: "Could not open SwiftLens. Launch SwiftLens.app once so macOS registers its URL scheme."
            }
        }
    }

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        guard let command = SwiftLensCommand(identifier: invocation.commandIdentifier) else {
            completionHandler(nil)
            return
        }
        let buffer = invocation.buffer
        do {
            switch command {
            case .expandMacros: try open(buffer, mode: "macros")
            case .showSyntaxTree: try open(buffer, mode: "tree")
            case .renderPreviews: try open(buffer, mode: "render")
            case .convertPreviewProviders:
                guard let converted = PreviewMigrator.convertPreviewProvidersToMacros(buffer.completeBuffer) else {
                    throw Failure.nothingToConvert
                }
                buffer.completeBuffer = converted
            case .wrapSelectionInPreview:
                guard let selection = buffer.selections.firstObject as? XCSourceTextRange else { throw Failure.emptySelection }
                let text = Self.text(in: selection, of: buffer)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptySelection }
                let indentation = String(repeating: buffer.usesTabsForIndentation ? "\t" : " ", count: buffer.usesTabsForIndentation ? 1 : buffer.indentationWidth)
                let preview = PreviewMigrator.wrapInPreview(Self.dedent(text), indentation: indentation)
                buffer.lines.add("")
                for line in preview.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                    buffer.lines.add(String(line))
                }
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// Hands the buffer (including unsaved edits) and cursor line to the SwiftLens app.
    private func open(_ buffer: XCSourceTextBuffer, mode: String) throws {
        let data = Data(buffer.completeBuffer.utf8)
        let code = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "swiftlens"
        components.host = "open"
        var items = [URLQueryItem(name: "mode", value: mode), URLQueryItem(name: "code", value: code)]
        if let selection = buffer.selections.firstObject as? XCSourceTextRange {
            items.append(URLQueryItem(name: "line", value: String(selection.start.line + 1)))
        }
        components.queryItems = items
        guard let url = components.url, NSWorkspace.shared.open(url) else { throw Failure.couldNotOpenApp }
    }

    static func text(in range: XCSourceTextRange, of buffer: XCSourceTextBuffer) -> String {
        var result = ""
        for lineIndex in range.start.line...min(range.end.line, buffer.lines.count - 1) {
            guard let line = buffer.lines[lineIndex] as? String else { continue }
            let characters = Array(line)
            let start = lineIndex == range.start.line ? min(range.start.column, characters.count) : 0
            let end = lineIndex == range.end.line ? min(range.end.column, characters.count) : characters.count
            if start < end { result += String(characters[start..<end]) }
            if lineIndex != range.end.line && !(result.hasSuffix("\n")) { result += "\n" }
        }
        return result
    }

    static func dedent(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let indentation = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(indentation)) }.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }
}
