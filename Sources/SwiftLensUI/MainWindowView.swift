#if os(macOS)
import SwiftLensCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(LensMode.allCases, selection: Binding(get: { model.mode }, set: { if let mode = $0 { model.mode = mode } })) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            if model.mode == .lab {
                MacroLabView(model: model)
            } else {
                HSplitView {
                    EditorPane(model: model).frame(minWidth: 320, idealWidth: 480)
                    resultPane.padding(10).frame(minWidth: 380, idealWidth: 560)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.loadFromClipboard()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open File", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .navigationTitle(model.fileURL?.lastPathComponent ?? "SwiftLens")
        .navigationSubtitle(model.mode.title)
        .frame(minWidth: 900, minHeight: 560)
        .onOpenURL { model.handle(url: $0) }
    }

    @ViewBuilder private var resultPane: some View {
        switch model.mode {
        case .macros: MacrosResultView(model: model)
        case .tree: SyntaxTreeResultView(model: model)
        case .render: RenderResultView(model: model)
        case .lab: EmptyView()
        }
    }
}

struct EditorPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.fileURL == nil ? "text.cursor" : "doc.text")
                Text(model.fileURL?.path ?? "Scratch — type, paste, or drop a .swift file")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.fileURL != nil {
                    Button("Save") { model.saveToFile() }.controlSize(.small).keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            CodeEditor(
                text: $model.source,
                revealRange: $model.revealRange,
                onCursorChange: { model.cursorMoved(utf16Offset: $0) },
                underlines: underlines
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.load(file: url) }
                }
                return true
            }
            if let message = model.statusMessage {
                Divider()
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.statusMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
    }

    /// Error ranges from the current mode's diagnostics, in UTF-16 units.
    private var underlines: [NSRange] {
        let diagnostics: [LensDiagnostic]
        switch model.mode {
        case .macros: diagnostics = model.expansion?.diagnostics ?? []
        case .render: diagnostics = model.renderReport?.compileDiagnostics ?? []
        default: diagnostics = []
        }
        return diagnostics.filter { $0.severity == .error }.compactMap { diagnostic -> NSRange? in
            if let highlight = diagnostic.highlights.first {
                let start = model.source.utf16OffsetFromUTF8(highlight.start.offset)
                let end = model.source.utf16OffsetFromUTF8(highlight.end.offset)
                return NSRange(location: start, length: max(1, end - start))
            }
            guard let position = diagnostic.position else { return nil }
            return NSRange(location: model.source.utf16OffsetFromUTF8(position.offset), length: 1)
        }
    }
}
#endif
