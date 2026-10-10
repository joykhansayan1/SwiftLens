#if os(macOS)
import SwiftLensCore
import SwiftUI

struct MacroLabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Implementation").font(.headline)
                Text("Any type conforming to ExpressionMacro, MemberMacro, … becomes a macro: StringifyMacro → #stringify, AddIDMacro → @AddID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CodeEditor(text: $model.labImplementation, underlines: [])
                Text("Usage").font(.headline)
                CodeEditor(text: $model.labUsage).frame(minHeight: 120, idealHeight: 160)
            }
            .padding(10)
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        model.runLab()
                    } label: {
                        Label("Build & Expand", systemImage: "hammer.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isBuildingLab)
                    if model.isBuildingLab { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let report = model.labReport {
                    DiffView(lines: TextDiff.lines(from: report.originalSource, to: report.expandedSource))
                    DiagnosticsList(diagnostics: report.diagnostics)
                } else {
                    Spacer()
                }
                DiagnosticsList(diagnostics: model.labDiagnostics)
                ScrollView {
                    Text(model.labBuildLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            .padding(10)
            .frame(minWidth: 360)
        }
    }
}
#endif
