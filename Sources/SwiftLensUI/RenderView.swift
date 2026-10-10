#if os(macOS)
import SwiftLensCore
import SwiftLensSandbox
import SwiftUI

struct RenderResultView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RenderControls(model: model)
            if let failure = model.renderReport?.agentFailure {
                Label {
                    Text(failure).font(.callout).textSelection(.enabled)
                } icon: {
                    Image(systemName: "bolt.trianglebadge.exclamationmark.fill").foregroundStyle(.red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text("The preview ran in an isolated process, so SwiftLens kept running.").font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostics = model.renderReport?.compileDiagnostics, !diagnostics.isEmpty {
                DiagnosticsList(diagnostics: diagnostics) { model.reveal($0.position) }
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(model.renderReport?.outputs ?? []) { output in
                        RenderCell(output: output)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if model.isRendering && (model.renderReport?.outputs.isEmpty ?? true) {
                    ProgressView("Compiling & rendering…")
                } else if model.previews.isEmpty && !model.isRendering {
                    Text("Add a #Preview { … } block, a PreviewProvider, or a View with init().")
                        .foregroundStyle(.secondary)
                }
            }
            if let report = model.renderReport {
                Text("\(report.cacheHit ? "cached build" : "compiled in \(Int(report.compileDurationMilliseconds)) ms") · rendered in \(Int(report.renderDurationMilliseconds)) ms")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct RenderControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Preview", selection: $model.selectedPreview) {
                    Text("All previews").tag(Int?.none)
                    ForEach(model.previews) { entry in
                        Text(entry.name).tag(Int?.some(entry.id))
                    }
                }
                .frame(maxWidth: 220)
                Toggle("Light", isOn: $model.renderSettings.light)
                Toggle("Dark", isOn: $model.renderSettings.dark)
                Toggle("RTL", isOn: $model.renderSettings.rtl)
                Menu("Dynamic Type") {
                    ForEach(RenderVariant.validDynamicTypeSizes, id: \.self) { size in
                        Toggle(size, isOn: Binding(
                            get: { model.renderSettings.dynamicTypeSizes.contains(size) },
                            set: { on in
                                if on { model.renderSettings.dynamicTypeSizes.insert(size) } else { model.renderSettings.dynamicTypeSizes.remove(size) }
                            }
                        ))
                    }
                }
                .frame(maxWidth: 140)
            }
            HStack(spacing: 12) {
                Picker("Canvas", selection: $model.renderSettings.device) {
                    Text("Size to fit").tag("")
                    ForEach(DevicePreset.all) { Text($0.name).tag($0.name) }
                }
                .frame(maxWidth: 240)
                TextField("Locales (en, ar, ja)", text: $model.renderSettings.locales)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Picker("Engine", selection: $model.renderSettings.engine) {
                    Text("AppKit").tag(RenderVariant.Engine.appKit)
                    Text("ImageRenderer").tag(RenderVariant.Engine.imageRenderer)
                }
                .frame(maxWidth: 200)
                Toggle("Auto", isOn: $model.renderSettings.autoRender).help("Re-render after you stop typing")
                Spacer()
                if model.isRendering { ProgressView().controlSize(.small) }
                Button("Render") { model.render() }.keyboardShortcut("r", modifiers: .command)
                Button(model.isLiveWindowOpen ? "Reload Live" : "Live Window") { model.openLiveWindow() }
                    .help("Interactive preview in a crash-isolated window; reloads on every render")
                Button {
                    model.exportRenders()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export PNGs")
                .disabled(model.renderReport?.outputs.isEmpty ?? true)
            }
        }
        .controlSize(.small)
    }
}

struct RenderCell: View {
    let output: RenderOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = output.imagePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(max(output.pointWidth, 1)), maxHeight: 520)
                    .background(CheckerboardBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .contextMenu {
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
            } else {
                Label(output.error ?? "No image", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(output.previewName).font(.callout.weight(.medium))
            Text("\(output.variant.label) · \(Int(output.pointWidth))×\(Int(output.pointHeight)) pt · \(Int(output.durationMilliseconds)) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            for row in 0..<Int(size.height / tile) + 1 {
                for column in 0..<Int(size.width / tile) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(.gray.opacity(0.12)))
                }
            }
        }
    }
}
#endif
