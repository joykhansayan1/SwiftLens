import SwiftLensCore
@testable import SwiftLensRenderer
@testable import SwiftLensSandbox
import SwiftParser
import SwiftParserDiagnostics
import XCTest

let sampleSnippet = """
import SwiftUI

struct Badge: View {
    var title: String
    var body: some View {
        Text(title).padding(8).background(.blue, in: Capsule())
    }
}

#Preview("Badge", traits: .sizeThatFitsLayout) {
    Badge(title: "New")
}

#Preview(traits: .fixedLayout(width: 320, height: 200), .landscapeLeft) {
    @Previewable @State var count = 3
    let label = "Count: \\(count)"
    Button(label) { count += 1 }
}

struct Badge_Previews: PreviewProvider {
    static var previews: some View {
        Badge(title: "Legacy")
    }
}

@main
struct DemoApp: App {
    var body: some Scene { WindowGroup { Badge(title: "App") } }
}
"""

final class PreviewExtractorTests: XCTestCase {
    func testExtractsPreviewsTraitsAndPreviewables() {
        let entries = PreviewExtractor.extract(SourceDocument(text: sampleSnippet))
        XCTAssertEqual(entries.map(\.name), ["Badge", "Preview 2", "Badge"])
        XCTAssertEqual(entries.map(\.kind), [.previewMacro, .previewMacro, .previewProvider])
        XCTAssertEqual(entries[0].traits, [.sizeThatFitsLayout])
        XCTAssertEqual(entries[1].traits, [.fixedLayout(width: 320, height: 200), .landscapeLeft])
        XCTAssertEqual(entries[1].previewableDeclarations, ["@State var count = 3"])
        XCTAssertEqual(entries[1].body, "let label = \"Count: \\(count)\"\nButton(label) { count += 1 }")
        XCTAssertEqual(entries[1].bodyLine, 16)
        XCTAssertEqual(entries[2].body, "Badge_Previews.previews")
        XCTAssertEqual(entries.map(\.id), [0, 1, 2])
    }

    func testFallsBackToDefaultConstructibleViews() {
        let source = """
        import SwiftUI
        struct A: View { var body: some View { Text("A") } }
        struct B: View { var name: String; var body: some View { Text(name) } }
        struct C: View { @State private var on = false; @Environment(\\.colorScheme) var scheme; var body: some View { Toggle("x", isOn: $on) } }
        struct D: View { @Binding var on: Bool; var body: some View { EmptyView() } }
        struct E<T>: View { var body: some View { EmptyView() } }
        """
        XCTAssertEqual(PreviewExtractor.extract(SourceDocument(text: source)).map(\.name), ["A", "C"])
    }
}

final class HarnessGeneratorTests: XCTestCase {
    func testBlankingPreservesLineNumbersAndRemovesMain() {
        let document = SourceDocument(text: sampleSnippet)
        let harness = HarnessGenerator.generate(document)
        let originalLines = sampleSnippet.split(separator: "\n", omittingEmptySubsequences: false)
        let snippetLines = harness.snippetSource.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(originalLines.count, snippetLines.count)
        XCTAssertFalse(harness.snippetSource.contains("#Preview"))
        XCTAssertFalse(harness.snippetSource.contains("@main"))
        XCTAssertTrue(harness.snippetSource.contains("struct DemoApp: App"))
        XCTAssertEqual(snippetLines[3], originalLines[3])
        // The blanked snippet must still parse cleanly.
        XCTAssertTrue(ParseDiagnosticsGenerator.diagnostics(for: Parser.parse(source: harness.snippetSource)).isEmpty)
    }

    func testGeneratedHarnessIsValidSwift() {
        let harness = HarnessGenerator.generate(SourceDocument(text: sampleSnippet), snippetPath: "/tmp/Snippet.swift")
        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: Parser.parse(source: harness.harnessSource))
        XCTAssertTrue(diagnostics.isEmpty, diagnostics.map(\.message).joined(separator: "\n") + "\n" + harness.harnessSource)
        XCTAssertTrue(harness.harnessSource.contains("struct __SwiftLensPreview_1: View {\n    @State var count = 3\n"))
        XCTAssertTrue(harness.harnessSource.contains("#sourceLocation(file: \"/tmp/Snippet.swift\", line: 16)"))
        XCTAssertTrue(harness.harnessSource.contains("case 2: return AnyView(__SwiftLensPreview_2())"))
        XCTAssertTrue(harness.harnessSource.contains("@_cdecl(\"swiftlens_render_png\")"))
        XCTAssertTrue(harness.harnessSource.contains(#"let __swiftLensPreviewNames: [String] = ["Badge", "Preview 2", "Badge"]"#))
    }
}

final class PreviewMigratorTests: XCTestCase {
    func testConvertsPreviewProviderToMacro() throws {
        let source = """
        import SwiftUI

        struct ContentView_Previews: PreviewProvider {
            static var previews: some View {
                ContentView()
                    .padding()
            }
        }
        """
        let converted = try XCTUnwrap(PreviewMigrator.convertPreviewProvidersToMacros(source))
        XCTAssertEqual(converted, """
        import SwiftUI

        #Preview("ContentView") {
            ContentView()
                .padding()
        }
        """)
        XCTAssertNil(PreviewMigrator.convertPreviewProvidersToMacros("struct A {}"))
    }

    func testWrapInPreview() {
        XCTAssertEqual(PreviewMigrator.wrapInPreview("Text(\"Hi\")", name: "Greeting"), "#Preview(\"Greeting\") {\n    Text(\"Hi\")\n}\n")
    }
}

final class RenderModelTests: XCTestCase {
    func testVariantMatrixAndLabels() {
        let variants = RenderVariant.matrix(colorSchemes: ["light", "dark"], dynamicTypeSizes: ["large", "accessibility3"], devices: [DevicePreset.named("iPhone 16")])
        XCTAssertEqual(variants.count, 4)
        XCTAssertEqual(variants.map(\.label), [
            "iPhone 16 · light · large", "iPhone 16 · light · accessibility3",
            "iPhone 16 · dark · large", "iPhone 16 · dark · accessibility3",
        ])
        XCTAssertTrue(variants.allSatisfy { $0.layout == .fixed && $0.width == 393 })
        XCTAssertEqual(RenderVariant.matrix().map(\.label), ["default"])
    }

    func testTraitsAdjustVariants() {
        let base = RenderVariant(label: "x", layout: .fixed, width: 393, height: 852)
        let landscape = base.applying([.landscapeLeft])
        XCTAssertEqual(landscape.width, 852)
        XCTAssertEqual(landscape.height, 393)
        let fixed = RenderVariant(label: "y").applying([.fixedLayout(width: 100, height: 50)])
        XCTAssertEqual(fixed.layout, .fixed)
        XCTAssertEqual(fixed.width, 100)
    }
}

final class SnippetCompilerTests: XCTestCase {
    func testCommandLine() {
        let compiler = SnippetCompiler(options: .init(swiftcPath: "/usr/bin/swiftc", sdkPath: "/SDK", extraArguments: ["-F", "/Frameworks"], deploymentTarget: "14.0"))
        let command = compiler.commandLine(sources: ["a.swift", "b.swift"], output: "/out/lib.dylib", moduleName: "M")
        XCTAssertEqual(command.first, "/usr/bin/swiftc")
        XCTAssertTrue(command.contains("-emit-library"))
        XCTAssertTrue(command.contains("-parse-as-library"))
        XCTAssertEqual(command[command.firstIndex(of: "-sdk")! + 1], "/SDK")
        XCTAssertEqual(command[command.firstIndex(of: "-target")! + 1], "\(SnippetCompiler.hostArchitecture)-apple-macos14.0")
        XCTAssertEqual(Array(command.suffix(4)), ["-F", "/Frameworks", "a.swift", "b.swift"])
    }

    func testDiagnosticsMapToSnippet() {
        let document = SourceDocument(text: "import SwiftUI\nlet x: Int = \"a\"\n")
        let log = """
        /cache/abc/Snippet.swift:2:14: error: cannot convert value of type 'String' to specified type 'Int'
        /cache/abc/Snippet.swift:2:14: note: some note
        /cache/abc/SwiftLensHarness.swift:40:1: warning: harness warning
        """
        let diagnostics = SnippetCompiler.parseDiagnostics(log, snippetPath: "/cache/abc/Snippet.swift", document: document)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics[0].position, SourcePosition(line: 2, column: 14, offset: 28))
        XCTAssertEqual(diagnostics[0].notes, ["some note"])
        XCTAssertNil(diagnostics[1].position)
        XCTAssertEqual(diagnostics[1].severity, .warning)
    }

    #if !os(macOS)
    func testCompilingOffMacOSReportsUnsupported() {
        let compiler = SnippetCompiler(options: .init(swiftcPath: "/usr/bin/swiftc", cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        XCTAssertThrowsError(try compiler.compile(SourceDocument(text: sampleSnippet)))
    }
    #endif
}

final class RenderClientTests: XCTestCase {
    func testCrashSummaryPicksRuntimeErrors() {
        let stderr = "noise\nSwift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range\nmore noise"
        XCTAssertEqual(RenderClient.crashSummary(stderr), "Swift/ContiguousArrayBuffer.swift:690: Fatal error: Index out of range")
    }

    func testSanitizeLabels() {
        XCTAssertEqual(RenderAgent.sanitize("iPhone 16 · dark"), "iPhone_16___dark")
    }
}
