#if os(macOS)
import SwiftLensMacroEngine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            MacroSettings(model: model).tabItem { Label("Macro Plugins", systemImage: "puzzlepiece.extension") }
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            ToolchainInfo().tabItem { Label("Toolchain", systemImage: "hammer") }
        }
        .frame(width: 620, height: 440)
        .padding()
    }
}

struct PathListEditor: View {
    let title: String
    let help: String
    @Binding var items: [String]
    var choosesDirectories = true
    var choosesFiles = true
    var suffix: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(items.indices, id: \.self) { index in
                    HStack {
                        TextField("", text: $items[index]).textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                        Button { items.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 70)
            Button("Add…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = choosesDirectories
                panel.canChooseFiles = choosesFiles
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK {
                    items += panel.urls.map { $0.path + suffix }
                }
            }
            .controlSize(.small)
        }
    }
}

struct MacroSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Expand Apple's macros (@Observable, #Preview, #Predicate, @Model, @Test, …)", isOn: $model.settings.useToolchainMacros)
                PathListEditor(
                    title: "Macro declarations",
                    help: "Files or folders containing your `macro` declarations (e.g. Sources/MyLibrary). SwiftLens reads them to know each macro's roles.",
                    items: $model.settings.declarationPaths
                )
                PathListEditor(
                    title: "Plugin search paths",
                    help: "Folders with built plugins: SwiftPM's .build/debug, Xcode's Build/Products/Debug, or folders of lib*Macros.dylib.",
                    items: $model.settings.pluginSearchPaths,
                    choosesFiles: false
                )
                PathListEditor(
                    title: "Executable plugins",
                    help: "Explicit plugin executables, in compiler syntax: /path/to/MyMacros#MyMacros",
                    items: $model.settings.executablePlugins,
                    choosesDirectories: false,
                    suffix: ""
                )
            }
            .padding(4)
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Global shortcut ⌥⌘L opens SwiftLens with the clipboard", isOn: $model.settings.hotKeyEnabled)
            Toggle("Reload opened files when they change on disk", isOn: $model.settings.watchOpenedFile)
            Toggle("Readable unique names in expansions (__name_1 instead of $s…fMu_)", isOn: $model.settings.readableNames)
            Stepper("Render timeout: \(Int(model.settings.renderTimeout)) s", value: $model.settings.renderTimeout, in: 3...120)
            TextField("Extra swiftc flags (space separated)", text: Binding(
                get: { model.settings.extraSwiftcArguments.joined(separator: " ") },
                set: { model.settings.extraSwiftcArguments = $0.split(separator: " ").map(String.init) }
            ))
            Text("Use -F/-I/-L to render views that import your own frameworks.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ToolchainInfo: View {
    @State private var description = "Detecting…"

    var body: some View {
        ScrollView {
            Text(description)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            let text = await Task.detached { () -> String in
                guard let toolchain = Toolchain.detect() else { return "No Swift toolchain found. Install Xcode or set SWIFTLENS_TOOLCHAIN." }
                let registry = MacroRegistry()
                registry.addToolchainMacros(toolchain)
                let macros = registry.allDefinitions.map { "  \($0.isFreestanding ? "#" : "@")\($0.name)  →  \($0.moduleName).\($0.typeName)" }
                return toolchain.description + "\n\nBuilt-in macros (\(macros.count)):\n" + macros.joined(separator: "\n")
            }.value
            description = text
        }
    }
}
#endif
