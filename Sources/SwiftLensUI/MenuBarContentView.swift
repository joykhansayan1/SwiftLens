#if os(macOS)
import SwiftLensCore
import SwiftUI

/// The compact popover shown from the menu bar.
struct MenuBarContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "eye.circle.fill").font(.title2).foregroundStyle(.tint)
                Text("SwiftLens").font(.headline)
                Spacer()
                Button {
                    model.openMainWindow?()
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open the full window (⌥⌘L)")
                SettingsLink14()
            }
            Picker("", selection: $model.mode) {
                ForEach(LensMode.allCases.filter { $0 != .lab }) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Button {
                    model.loadFromClipboard()
                } label: {
                    Label("From Clipboard", systemImage: "doc.on.clipboard")
                }
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
                Spacer()
            }
            .controlSize(.small)

            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: 440, height: 520)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .macros:
            if let report = model.expansion {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.expansions.filter { !$0.isNested }) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(record.spelling).font(.system(.callout, design: .monospaced).bold())
                                    RoleBadge(role: record.role.rawValue)
                                    Spacer()
                                    if let position = record.position { Text("line \(position.line)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(record.expandedSource)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        if report.expansions.isEmpty { Text("No macros found in the current code.").foregroundStyle(.secondary) }
                        DiagnosticsList(diagnostics: report.diagnostics)
                    }
                }
            } else {
                ProgressView()
            }
        case .tree:
            if let tree = model.tree {
                ScrollView([.vertical, .horizontal]) {
                    Text(tree.asciiTree(showSpans: false))
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                ProgressView()
            }
        case .render:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(model.renderReport?.outputs ?? []) { output in
                        if let path = output.imagePath, let image = NSImage(contentsOfFile: path) {
                            VStack(spacing: 4) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 220)
                                Text(output.variant.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.isRendering { ProgressView() }
                if let failure = model.renderReport?.agentFailure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        case .lab:
            EmptyView()
        }
    }
}

/// `SettingsLink` exists from macOS 14; fall back to the legacy selector before that.
struct SettingsLink14: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Image(systemName: "gearshape") }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }
}
#endif
