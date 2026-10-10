#if os(macOS)
import AppKit
import SwiftLensCore
import SwiftUI

enum Theme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static func color(for kind: HighlightToken.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .string: .systemRed
        case .number: .systemPurple
        case .comment: .secondaryLabelColor
        case .docComment: .systemGreen
        case .attribute: .systemOrange
        case .operator: .labelColor
        case .directive: .systemBrown
        case .label: .systemIndigo
        case .placeholder: .systemGray
        case .regex: .systemRed
        }
    }

    static func roleColor(_ role: String) -> Color {
        switch role {
        case "expression", "declaration", "codeItem": .blue
        case "member": .purple
        case "memberAttribute": .indigo
        case "extension", "conformance": .teal
        case "peer": .orange
        case "accessor": .pink
        case "body", "preamble": .green
        default: .gray
        }
    }
}

/// A plain-text Swift editor backed by `NSTextView`, highlighted by swift-syntax's classifier.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// When set, the editor selects and scrolls to the range, then resets the binding.
    var revealRange: Binding<NSRange?>?
    var onCursorChange: ((Int) -> Void)?
    /// Ranges (UTF-16) to underline, e.g. diagnostics.
    var underlines: [NSRange] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Theme.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.string = text
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.highlight(textView)
        } else if context.coordinator.lastUnderlines != underlines {
            context.coordinator.highlight(textView)
        }
        if let binding = revealRange, let range = binding.wrappedValue {
            let length = (textView.string as NSString).length
            let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
            textView.setSelectedRange(clamped)
            textView.scrollRangeToVisible(clamped)
            textView.showFindIndicator(for: clamped)
            DispatchQueue.main.async { binding.wrappedValue = nil }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lastUnderlines: [NSRange] = []
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCursorChange?(textView.selectedRange().location)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            let full = NSRange(location: 0, length: (text as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: Theme.font, .foregroundColor: NSColor.labelColor], range: full)
            // Highlighting very large files is skipped to keep typing smooth.
            if full.length < 400_000 {
                for token in SyntaxHighlighter.highlight(text) {
                    let range = NSRange(location: token.utf16Offset, length: token.utf16Length)
                    guard NSMaxRange(range) <= full.length else { continue }
                    storage.addAttribute(.foregroundColor, value: Theme.color(for: token.kind), range: range)
                }
            }
            for range in parent.underlines where NSMaxRange(range) <= full.length {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.systemRed,
                ], range: range)
            }
            storage.endEditing()
            lastUnderlines = parent.underlines
        }
    }
}

/// Read-only code with line numbers and per-line backgrounds, used for diffs.
struct DiffView: View {
    let lines: [TextDiff.Line]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(line.oldLine.map(String.init) ?? "")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(line.newLine.map(String.init) ?? "")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.tertiary)
                        Text(marker(line.operation))
                            .frame(width: 18)
                            .foregroundStyle(color(line.operation))
                        Text(line.text.isEmpty ? " " : line.text)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(line.operation).opacity(line.operation == .equal ? 0 : 0.14))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }

    private func marker(_ operation: TextDiff.Operation) -> String {
        switch operation {
        case .equal: " "
        case .insert: "+"
        case .delete: "−"
        }
    }

    private func color(_ operation: TextDiff.Operation) -> Color {
        switch operation {
        case .equal: .primary
        case .insert: .green
        case .delete: .red
        }
    }
}

struct DiagnosticsList: View {
    let diagnostics: [LensDiagnostic]
    var onSelect: (LensDiagnostic) -> Void = { _ in }

    var body: some View {
        if !diagnostics.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Button {
                        onSelect(diagnostic)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: icon(diagnostic.severity))
                                .foregroundStyle(tint(diagnostic.severity))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(diagnostic.message).font(.callout)
                                HStack(spacing: 8) {
                                    if let position = diagnostic.position { Text("line \(position.line):\(position.column)") }
                                    if let macro = diagnostic.macroName { Text("@\(macro)") }
                                    ForEach(diagnostic.fixIts, id: \.message) { Text("Fix-it: \($0.message)").foregroundStyle(.green) }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func icon(_ severity: LensSeverity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note, .remark: "info.circle.fill"
        }
    }

    private func tint(_ severity: LensSeverity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .yellow
        case .note, .remark: .blue
        }
    }
}
#endif
