#if os(macOS)
import SwiftLensCore
import SwiftLensMacroEngine
import SwiftUI

struct MacrosResultView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $model.expansionStyle) {
                    ForEach(ExpansionStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                if model.isExpanding { ProgressView().controlSize(.small) }
                if let report = model.expansion {
                    let stats = TextDiff.stats(TextDiff.lines(from: report.originalSource, to: report.expandedSource))
                    Text("\(report.expansions.count) expansions · +\(stats.insertions) −\(stats.deletions) · \(String(format: "%.0f", report.durationMilliseconds)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.expandedSource, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy expanded source")
                }
            }

            if let report = model.expansion {
                switch model.expansionStyle {
                case .expanded:
                    CodeEditor(text: .constant(report.expandedSource), isEditable: false)
                case .diff:
                    DiffView(lines: TextDiff.lines(from: report.originalSource, to: report.expandedSource))
                case .list:
                    ExpansionList(report: report) { model.reveal($0.position) }
                }
                if !report.unresolvedMacros.isEmpty {
                    Label {
                        Text("No declaration for \(report.unresolvedMacros.map(\.spelling).joined(separator: ", ")). Add your macro library in Settings → Macro Plugins.")
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                DiagnosticsList(diagnostics: report.diagnostics) { model.reveal($0.position) }
            } else {
                Spacer()
                Text("Paste or type Swift code on the left.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

struct ExpansionList: View {
    let report: ExpansionReport
    var onSelect: (ExpansionRecord) -> Void

    var body: some View {
        List(report.expansions) { record in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(record.spelling).font(.system(.body, design: .monospaced).bold())
                    RoleBadge(role: record.role.rawValue)
                    if record.isNested {
                        Text("nested").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.gray.opacity(0.2), in: Capsule())
                    }
                    if let attachedTo = record.attachedTo { Text("on \(attachedTo)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let position = record.position {
                        Button("line \(position.line)") { onSelect(record) }.buttonStyle(.link).font(.caption)
                    }
                    Text("\(String(format: "%.1f", record.durationMilliseconds)) ms").font(.caption).foregroundStyle(.tertiary)
                }
                Text(record.expandedSource.isEmpty ? "(empty expansion)" : record.expandedSource)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                Text("\(record.moduleName).\(record.typeName)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }
}

struct RoleBadge: View {
    let role: String

    var body: some View {
        Text(role)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Theme.roleColor(role))
            .background(Theme.roleColor(role).opacity(0.15), in: Capsule())
    }
}
#endif
