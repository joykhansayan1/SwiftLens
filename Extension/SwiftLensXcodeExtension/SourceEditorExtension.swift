import AppKit
import Foundation
import XcodeKit

/// Xcode ▸ Editor ▸ SwiftLens
///
/// The extension is sandboxed, so commands that need the compiler or macro plugins hand the current buffer to
/// the SwiftLens app through its URL scheme. Pure syntax transformations run right here.
final class SourceEditorExtension: NSObject, XCSourceEditorExtension {
    var commandDefinitions: [[XCSourceEditorCommandDefinitionKey: Any]] {
        SwiftLensCommand.allCases.map { command in
            [
                .classNameKey: NSStringFromClass(SourceEditorCommand.self),
                .identifierKey: command.identifier,
                .nameKey: command.title,
            ]
        }
    }
}

enum SwiftLensCommand: String, CaseIterable {
    case expandMacros
    case showSyntaxTree
    case renderPreviews
    case convertPreviewProviders
    case wrapSelectionInPreview

    var identifier: String { "dev.swiftlens.xcode.\(rawValue)" }

    var title: String {
        switch self {
        case .expandMacros: "Expand Macros in SwiftLens"
        case .showSyntaxTree: "Show Syntax Tree in SwiftLens"
        case .renderPreviews: "Render Previews in SwiftLens"
        case .convertPreviewProviders: "Convert PreviewProvider to #Preview"
        case .wrapSelectionInPreview: "Wrap Selection in #Preview"
        }
    }

    init?(identifier: String) {
        guard let command = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = command
    }
}
