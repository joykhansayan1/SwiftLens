#if os(macOS)
import AppKit
import Foundation
import SwiftLensCore
import SwiftLensMacroEngine
import SwiftLensRenderer
import SwiftLensSandbox
import SwiftUI
import UniformTypeIdentifiers

public enum LensMode: String, CaseIterable, Identifiable, Codable {
    case macros, tree, render, lab

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macros: "Macros"
        case .tree: "Syntax Tree"
        case .render: "Render"
        case .lab: "Macro Lab"
        }
    }

    public var systemImage: String {
        switch self {
        case .macros: "wand.and.stars"
        case .tree: "list.bullet.indent"
        case .render: "photo.on.rectangle.angled"
        case .lab: "testtube.2"
        }
    }
}

enum ExpansionStyle: String, CaseIterable, Identifiable {
    case expanded = "Expanded File"
    case diff = "Diff"
    case list = "Expansions"

    var id: String { rawValue }
}

/// User preferences, persisted as JSON in UserDefaults.
public struct LensSettings: Codable, Equatable {
    public var executablePlugins: [String] = []
    public var pluginSearchPaths: [String] = []
    public var declarationPaths: [String] = []
    public var useToolchainMacros = true
    public var readableNames = true
    public var hotKeyEnabled = true
    public var inProcessLiveCanvas = false
    public var renderTimeout: Double = 15
    public var extraSwiftcArguments: [String] = []
    public var watchOpenedFile = true

    static let key = "SwiftLensSettings"

    static func load() -> LensSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(LensSettings.self, from: data) else { return LensSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Render controls shown above the preview grid.
struct RenderSettings: Equatable {
    var light = true
    var dark = true
    var dynamicTypeSizes: Set<String> = ["large"]
    var device: String = ""
    var rtl = false
    var locales = ""
    var engine: RenderVariant.Engine = .appKit
    var autoRender = true
    var scale: Double = 2

    func variants() -> [RenderVariant] {
        var schemes: [String] = []
        if light { schemes.append("light") }
        if dark { schemes.append("dark") }
        if schemes.isEmpty { schemes = ["light"] }
        let sizes = RenderVariant.validDynamicTypeSizes.filter { dynamicTypeSizes.contains($0) }
        let localeList = locales.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return RenderVariant.matrix(
            colorSchemes: schemes,
            dynamicTypeSizes: sizes.isEmpty ? ["large"] : sizes,
            locales: localeList.isEmpty ? [nil] : localeList.map { Optional($0) },
            layoutDirections: rtl ? ["leftToRight", "rightToLeft"] : ["leftToRight"],
            devices: [DevicePreset.named(device)],
            engine: engine,
            scale: scale
        )
    }
}

/// A unit of background work whose result is applied on the main actor; stale results are dropped.
private final class Generation: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ candidate: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return candidate == value }
}

/// Wraps non-Sendable engine objects that are only ever used from `AppModel.workQueue`.
private final class Engines: @unchecked Sendable {
    var expander: MacroExpander?
    var expanderSettings: LensSettings?
}

@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    @Published public var mode: LensMode = .macros {
        didSet { scheduleUpdate(immediately: true) }
    }
    @Published public var source: String = AppModel.sampleSource {
        didSet { if source != oldValue { scheduleUpdate() } }
    }
    @Published public private(set) var fileURL: URL?
    @Published var statusMessage: String?

    // Macros
    @Published var expansion: ExpansionReport?
    @Published var expansionStyle: ExpansionStyle = .expanded
    @Published var isExpanding = false

    // Syntax tree
    @Published var tree: SyntaxTreeNode?
    @Published var treeShowsTokens = true
    @Published var cursorPath: [SyntaxTreeNode] = []
    @Published var selectedNodeID: Int?
    @Published var revealRange: NSRange?

    // Render
    @Published var previews: [PreviewEntry] = []
    @Published var renderSettings = RenderSettings() {
        didSet { if renderSettings != oldValue, renderSettings.autoRender, mode == .render { scheduleUpdate() } }
    }
    @Published var selectedPreview: Int?
    @Published var renderReport: RenderReport?
    @Published var isRendering = false
    @Published var liveLibrary: (path: String, index: Int)?

    // Macro Lab
    @Published var labImplementation: String = AppModel.sampleLabImplementation
    @Published var labUsage: String = AppModel.sampleLabUsage
    @Published var labReport: ExpansionReport?
    @Published var labBuildLog = ""
    @Published var labDiagnostics: [LensDiagnostic] = []
    @Published var isBuildingLab = false

    @Published public var settings = LensSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            scheduleUpdate(immediately: true)
        }
    }

    public var openMainWindow: (() -> Void)?

    let workQueue = DispatchQueue(label: "dev.swiftlens.work", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "dev.swiftlens.render", qos: .userInitiated)
    private let generation = Generation()
    private let renderGeneration = Generation()
    private let engines = Engines()
    private var debounce: Task<Void, Never>?
    private var fileWatcher: Timer?
    private var fileModificationDate: Date?
    private var liveProcess: Process?
    private var liveFrame: [Double]?

    public init() {
        scheduleUpdate(immediately: true)
    }

    // MARK: Input

    public func load(file url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        fileURL = url
        fileModificationDate = modificationDate(of: url)
        source = text
        startWatchingFile()
    }

    public func loadFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            statusMessage = "Clipboard has no text"
            return
        }
        fileURL = nil
        stopWatchingFile()
        source = text
        statusMessage = "Loaded \(text.split(separator: "\n").count) lines from the clipboard"
    }

    public func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.swiftSource, .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            load(file: url)
        }
    }

    /// `swiftlens://open?mode=macros&code=<base64url>` or `swiftlens://open?mode=render&file=/path/File.swift`
    public func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let raw = items["mode"], let requested = LensMode(rawValue: raw) { mode = requested }
        if let path = items["file"], !path.isEmpty {
            load(file: URL(fileURLWithPath: path))
        } else if let code = items["code"], let data = Data(base64URLEncoded: code), let text = String(data: data, encoding: .utf8) {
            fileURL = nil
            stopWatchingFile()
            source = text
        }
        if let line = items["line"].flatMap(Int.init) { reveal(line: line) }
        openMainWindow?()
    }

    func reveal(line: Int) {
        let lines = source.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let location = lines[..<(line - 1)].reduce(0) { $0 + ($1 as NSString).length + 1 }
        revealRange = NSRange(location: location, length: (lines[line - 1] as NSString).length)
    }

    func reveal(_ position: SourcePosition?) {
        guard let position else { return }
        reveal(line: position.line)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func startWatchingFile() {
        stopWatchingFile()
        guard settings.watchOpenedFile else { return }
        fileWatcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFileForChanges() }
        }
    }

    private func stopWatchingFile() {
        fileWatcher?.invalidate()
        fileWatcher = nil
    }

    private func checkFileForChanges() {
        guard let url = fileURL, let date = modificationDate(of: url), date != fileModificationDate else { return }
        fileModificationDate = date
        if let text = try? String(contentsOf: url, encoding: .utf8), text != source {
            source = text
        }
    }

    func saveToFile() {
        guard let url = fileURL else { return }
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            fileModificationDate = modificationDate(of: url)
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: Updates

    func scheduleUpdate(immediately: Bool = false) {
        debounce?.cancel()
        let delay: UInt64 = immediately ? 0 : (mode == .render ? 900_000_000 : 250_000_000)
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            self?.runUpdate()
        }
    }

    private func runUpdate() {
        switch mode {
        case .macros: expand()
        case .tree: buildTree()
        case .render:
            previews = PreviewExtractor.extract(SourceDocument(text: source))
            if renderSettings.autoRender { render() }
        case .lab: break
        }
    }

    func expand() {
        let text = source
        let name = fileURL?.lastPathComponent ?? "Snippet.swift"
        let settings = settings
        let token = generation.next()
        isExpanding = true
        let engines = engines
        workQueue.async { [weak self] in
            if engines.expander == nil || engines.expanderSettings != settings {
                engines.expander?.host.shutdown()
                engines.expander = AppModel.makeExpander(settings)
                engines.expanderSettings = settings
            }
            guard let expander = engines.expander else { return }
            let report = expander.expand(
                SourceDocument(text: text, fileName: name),
                options: MacroExpansionOptions(readableUniqueNames: settings.readableNames)
            )
            Task { @MainActor [weak self] in
                guard let self, self.generation.isCurrent(token) else { return }
                self.expansion = report
                self.isExpanding = false
            }
        }
    }

    /// Builds an expander for the given settings. Runs on `workQueue`; plugin processes are reused until the
    /// settings change.
    nonisolated static func makeExpander(_ settings: LensSettings) -> MacroExpander {
        let toolchain = Toolchain.detect()
        let registry = MacroRegistry()
        if settings.useToolchainMacros, let toolchain { registry.addToolchainMacros(toolchain) }
        registry.addDeclarations(fromPaths: settings.declarationPaths)
        var configuration = MacroPluginHost.Configuration()
        configuration.executablePlugins = settings.executablePlugins.map(ExecutablePlugin.init(argument:))
        configuration.pluginSearchPaths = settings.pluginSearchPaths
        configuration.useToolchainPlugins = settings.useToolchainMacros
        return MacroExpander(registry: registry, host: MacroPluginHost(configuration: configuration, toolchain: toolchain))
    }

    func buildTree() {
        let text = source
        let showTokens = treeShowsTokens
        let token = generation.next()
        workQueue.async { [weak self] in
            let document = SourceDocument(text: text)
            let tree = SyntaxTreeBuilder.build(document, options: .init(includeTokens: showTokens))
            Task { @MainActor [weak self] in
                guard let self, self.generation.isCurrent(token) else { return }
                self.tree = tree
            }
        }
    }

    /// Called by the editor when the cursor moves (UTF-16 offset).
    func cursorMoved(utf16Offset: Int) {
        // Selecting a node in the tree moves the editor selection; don't let that feed back into the tree.
        if let lastTreeSelection, Date().timeIntervalSince(lastTreeSelection) < 0.4 { return }
        guard mode == .tree, let tree else { return }
        let utf8Offset = source.utf8OffsetFromUTF16(utf16Offset)
        cursorPath = tree.path(toOffset: utf8Offset)
        selectedNodeID = cursorPath.last?.id
    }

    private var lastTreeSelection: Date?

    func select(node: SyntaxTreeNode) {
        lastTreeSelection = Date()
        if selectedNodeID != node.id { selectedNodeID = node.id }
        let start = source.utf16OffsetFromUTF8(node.span.start.offset)
        let end = source.utf16OffsetFromUTF8(node.span.end.offset)
        revealRange = NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Rendering

    private func renderPipeline() -> RenderPipeline {
        let toolchain = Toolchain.detect()
        let compiler = SnippetCompiler(options: .init(swiftcPath: toolchain?.swiftcPath, sdkPath: toolchain?.sdkPath, extraArguments: settings.extraSwiftcArguments))
        return RenderPipeline(compiler: compiler, client: RenderClient(agentExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0]))
    }

    func render() {
        let document = SourceDocument(text: source, fileName: "Snippet.swift")
        let variants = renderSettings.variants()
        let indices = selectedPreview.map { [$0] } ?? []
        let timeout = settings.renderTimeout
        let pipeline = renderPipeline()
        let token = renderGeneration.next()
        isRendering = true
        renderQueue.async { [weak self] in
            let (report, compiled) = pipeline.render(document, variants: variants, previewIndices: indices, timeout: timeout)
            Task { @MainActor [weak self] in
                guard let self, self.renderGeneration.isCurrent(token) else { return }
                self.renderReport = report
                self.isRendering = false
                if let compiled { self.liveLibrary = (compiled.libraryPath, self.selectedPreview ?? 0) }
                if self.liveProcess?.isRunning == true { self.openLiveWindow() }
            }
        }
    }

    /// Opens (or refreshes) the crash-isolated interactive window for the selected preview.
    func openLiveWindow() {
        guard let library = liveLibrary else {
            statusMessage = "Render once before opening a live window"
            return
        }
        let index = selectedPreview ?? library.index
        let entry = previews.first { $0.id == index }
        let variant = (renderSettings.variants().first ?? RenderVariant(label: "default")).applying(entry?.traits ?? [])
        liveProcess?.terminate()
        do {
            let client = RenderClient(agentExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0])
            liveProcess = try client.openLiveWindow(
                LiveWindowJob(libraryPath: library.path, previewIndex: index, variant: variant, title: entry?.name ?? "Preview", frame: liveFrame)
            ) { [weak self] frame in
                Task { @MainActor in self?.liveFrame = frame }
            }
        } catch {
            statusMessage = "Could not open live window: \(error)"
        }
    }

    func closeLiveWindow() {
        liveProcess?.terminate()
        liveProcess = nil
    }

    var isLiveWindowOpen: Bool { liveProcess?.isRunning == true }

    func exportRenders() {
        guard let outputs = renderReport?.outputs.compactMap(\.imagePath), !outputs.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        for path in outputs {
            let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(atPath: path, toPath: destination.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: Macro Lab

    func runLab() {
        guard let swift = Toolchain.detect()?.swiftPath else {
            labBuildLog = "No Swift toolchain found. Install Xcode or set SWIFTLENS_TOOLCHAIN."
            return
        }
        let implementation = labImplementation
        let usage = labUsage
        isBuildingLab = true
        labBuildLog = "Building… (the first build compiles swift-syntax and takes a minute)"
        workQueue.async { [weak self] in
            let lab = MacroLab(swiftPath: swift)
            let (build, report) = lab.run(implementation: implementation, usage: usage)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBuildingLab = false
                self.labDiagnostics = build.diagnostics
                self.labBuildLog = build.succeeded ? "Built in \(String(format: "%.1f", build.durationMilliseconds / 1000)) s" : build.log
                self.labReport = report
            }
        }
    }

    // MARK: Samples

    static let sampleSource = """
    import SwiftUI
    import Observation

    @Observable
    final class Counter {
        var count = 0
        @ObservationIgnored var history: [Int] = []
    }

    struct CounterView: View {
        @State private var counter = Counter()

        var body: some View {
            VStack(spacing: 12) {
                Text("\\(counter.count)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Button("Increment") { counter.count += 1 }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }

    #Preview("Counter", traits: .sizeThatFitsLayout) {
        CounterView()
    }
    """

    static let sampleLabImplementation = """
    import SwiftSyntax
    import SwiftSyntaxMacros

    /// `#stringify(a + b)` → `(a + b, "a + b")`
    public struct StringifyMacro: ExpressionMacro {
        public static func expansion(
            of node: some FreestandingMacroExpansionSyntax,
            in context: some MacroExpansionContext
        ) -> ExprSyntax {
            guard let argument = node.arguments.first?.expression else { return "()" }
            return "(\\(argument), \\(literal: argument.description))"
        }
    }
    """

    static let sampleLabUsage = """
    let (result, code) = #stringify(6 * 7)
    """
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

extension String {
    func utf8OffsetFromUTF16(_ utf16Offset: Int) -> Int {
        let index = String.Index(utf16Offset: min(max(0, utf16Offset), utf16.count), in: self)
        return utf8.distance(from: utf8.startIndex, to: index)
    }

    func utf16OffsetFromUTF8(_ utf8Offset: Int) -> Int {
        let clamped = min(max(0, utf8Offset), utf8.count)
        let index = utf8.index(utf8.startIndex, offsetBy: clamped)
        return utf16.distance(from: utf16.startIndex, to: index)
    }
}
#endif
