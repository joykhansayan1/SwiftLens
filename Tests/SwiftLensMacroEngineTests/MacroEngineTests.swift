import SwiftLensCore
@testable import SwiftLensMacroEngine
import XCTest

final class MacroDeclarationScannerTests: XCTestCase {
    func testScansRolesConformancesAndLabels() throws {
        let definitions = MacroDeclarationScanner.scan(source: try TestSupport.fixture("DemoMacroDeclarations.swift"), origin: "test")
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        XCTAssertEqual(byName.count, 6)
        XCTAssertEqual(byName["stringify"]?.roles, [.expression])
        XCTAssertEqual(byName["stringify"]?.typeName, "StringifyMacro")
        XCTAssertEqual(byName["stringify"]?.moduleName, "SwiftLensDemoMacros")
        XCTAssertEqual(byName["AutoDescription"]?.roles, [.extension])
        XCTAssertEqual(byName["AutoDescription"]?.conformances, ["CustomStringConvertible"])
        XCTAssertEqual(byName["UserDefault"]?.parameterLabels, [nil])
        XCTAssertTrue(byName["MemberwiseInit"]?.isFreestanding == false)
    }

    func testInterfaceFastPath() {
        let interface = """
        import Swift
        public struct Unrelated {}
        @attached(member, names: named(_$observationRegistrar)) @attached(memberAttribute) @attached(extension, conformances: Observation::Observable) public macro Observable() = #externalMacro(module: "ObservationMacros", type: "ObservableMacro")
        @available(macOS 14, *)
        @attached(accessor) public macro ObservationIgnored() = #externalMacro(module: "ObservationMacros", type: "ObservationIgnoredMacro")
        """
        let definitions = MacroDeclarationScanner.scanInterface(text: interface, origin: "x.swiftinterface", declaringModule: "Observation")
        XCTAssertEqual(definitions.map(\.name), ["Observable", "ObservationIgnored"])
        XCTAssertEqual(definitions[0].roles, [.member, .memberAttribute, .extension])
        XCTAssertEqual(definitions[0].declaringModule, "Observation")
    }

    func testOverloadResolutionPrefersMatchingLabels() {
        let source = """
        @freestanding(declaration) public macro Preview(_ name: String? = nil, body: @escaping () -> Any) = #externalMacro(module: "PreviewsMacros", type: "SwiftUIView")
        @freestanding(declaration) public macro Preview(_ name: String? = nil, traits: Int, body: @escaping () -> Any) = #externalMacro(module: "PreviewsMacros", type: "SwiftUIViewWithTraits")
        """
        let registry = MacroRegistry(MacroDeclarationScanner.scan(source: source, origin: "t"))
        XCTAssertEqual(registry.resolve(name: "Preview", attached: false, labels: [nil, "traits"], hasTrailingClosure: true)?.typeName, "SwiftUIViewWithTraits")
        XCTAssertEqual(registry.resolve(name: "Preview", attached: false, labels: [nil], hasTrailingClosure: true)?.typeName, "SwiftUIView")
    }
}

final class UniqueNamePrettifierTests: XCTestCase {
    func testRewritesCompilerUniqueNames() {
        let prettifier = UniqueNamePrettifier()
        let text = "func access<$s3obs7Counter10ObservablefMm_6MemberfMu_>(k: $s3obs7Counter10ObservablefMm_6MemberfMu_, o: $s3obs7Counter10ObservablefMm_6MemberfMu0_)"
        XCTAssertEqual(prettifier.rewrite(text), "func access<__Member_1>(k: __Member_1, o: __Member_2)")
    }

    func testLeavesOtherDollarIdentifiersAlone() {
        XCTAssertEqual(UniqueNamePrettifier().rewrite("let $0 = $state"), "let $0 = $state")
    }
}

final class CompilerExpansionDumpTests: XCTestCase {
    func testParsesDumpAndDemanglesRoles() {
        let dump = """
        @__swiftmacro_3obs7Counter10ObservablefMm_.swift
        ------------------------------
        @ObservationIgnored private let _$observationRegistrar = Observation.ObservationRegistrar()
        ------------------------------
        @__swiftmacro_3obs7CounterC5count18ObservationTrackedfMa_.swift
        ------------------------------
        {
            get { _count }
        }
        ------------------------------
        @__swiftmacro_3obs7Counter10ObservablefMe_.swift
        ------------------------------
        extension Counter: Observation.Observable {
        }
        ------------------------------
        """
        let expansions = CompilerExpansionDump.parse(dump)
        XCTAssertEqual(expansions.count, 3)
        XCTAssertEqual(expansions[0].macroName, "Observable")
        XCTAssertEqual(expansions[0].role, .member)
        XCTAssertEqual(expansions[1].macroName, "ObservationTracked")
        XCTAssertEqual(expansions[1].role, .accessor)
        XCTAssertEqual(expansions[2].role, .extension)
        XCTAssertTrue(expansions[2].expandedSource.contains("extension Counter"))
    }
}

final class PluginHostEndToEndTests: XCTestCase {
    var expander: MacroExpander!

    override func setUpWithError() throws {
        guard let plugin = TestSupport.demoPluginPath else {
            throw XCTSkip("Demo plugin not built (swift build --product SwiftLensDemoMacros)")
        }
        var configuration = MacroPluginHost.Configuration()
        configuration.executablePlugins = [ExecutablePlugin(path: plugin, modules: ["SwiftLensDemoMacros"])]
        configuration.useToolchainPlugins = false
        let registry = MacroRegistry(MacroDeclarationScanner.scan(source: try TestSupport.fixture("DemoMacroDeclarations.swift"), origin: "decls"))
        expander = MacroExpander(registry: registry, host: MacroPluginHost(configuration: configuration, toolchain: nil))
    }

    override func tearDown() {
        expander?.host.shutdown()
    }

    func testPluginHandshake() throws {
        let connection = try expander.host.connection(for: "SwiftLensDemoMacros")
        XCTAssertGreaterThanOrEqual(connection.capability?.protocolVersion ?? 0, 1)
    }

    func testExpandsEveryRoleInAFile() throws {
        let report = expander.expand(source: try TestSupport.fixture("DemoUsage.swift"), fileName: "Usage.swift")
        let expanded = report.expandedSource

        XCTAssertTrue(expanded.contains("public init(name: String, age: Int = 0, theme: String = \"light\")") ||
                      expanded.contains("public init(name: String, age: Int = 0)"), expanded)
        XCTAssertTrue(expanded.contains("extension User: CustomStringConvertible"), expanded)
        XCTAssertTrue(expanded.contains("func fetchUser(id: Int) async -> User"), expanded)
        XCTAssertTrue(expanded.contains("UserDefaults.standard.object(forKey: \"theme\")"), expanded)
        XCTAssertTrue(expanded.contains("let apiKey = \"apiKey\""), expanded)
        XCTAssertTrue(expanded.contains("(1 + 2 * 3, \"1 + 2 * 3\")"), expanded)
        XCTAssertFalse(expanded.contains("#stringify"), expanded)
        XCTAssertFalse(expanded.contains("@AutoDescription"), expanded)

        let roles = Set(report.expansions.map(\.role))
        XCTAssertEqual(roles, [.member, .extension, .peer, .accessor, .declaration, .expression])
        XCTAssertTrue(report.unresolvedMacros.isEmpty, "\(report.unresolvedMacros)")
        XCTAssertFalse(report.unifiedDiff.isEmpty)

        // Readable unique names instead of `$sLens…fMu_`.
        XCTAssertFalse(expanded.contains("fMu_"), expanded)
        XCTAssertTrue(expanded.contains("__continuation_1"), expanded)
    }

    func testMacroDiagnosticsMapBackToSource() throws {
        let report = expander.expand(source: try TestSupport.fixture("DemoUsage.swift"), fileName: "Usage.swift")
        let diagnostic = try XCTUnwrap(report.diagnostics.first { $0.message.contains("can only be applied to a struct or class") })
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.macroName, "MemberwiseInit")
        XCTAssertEqual(diagnostic.position?.line, 24)
        XCTAssertEqual(diagnostic.fixIts.first?.message, "Remove '@MemberwiseInit'")
    }

    func testUnknownMacrosAreReported() {
        let report = expander.expand(source: "@Unknown struct S {}\nlet x = #nope(1)\n@State var y = 1")
        XCTAssertEqual(Set(report.unresolvedMacros.map(\.spelling)), ["@Unknown", "#nope"])
    }

    func testRepeatedExpansionReusesPluginProcess() throws {
        let first = try expander.host.connection(for: "SwiftLensDemoMacros")
        _ = expander.expand(source: "let a = #stringify(1)")
        _ = expander.expand(source: "let b = #stringify(2)")
        let second = try expander.host.connection(for: "SwiftLensDemoMacros")
        XCTAssertTrue(first === second)
    }
}

final class ToolchainMacroTests: XCTestCase {
    func testObservableExpandsThroughPluginServer() throws {
        guard let toolchain = Toolchain.detect(), toolchain.pluginServerPath != nil,
              toolchain.libraryPlugins()["ObservationMacros"] != nil
        else { throw XCTSkip("No toolchain with ObservationMacros available") }
        let registry = MacroRegistry()
        registry.addToolchainMacros(toolchain, useCache: false)
        XCTAssertFalse(registry.definitions(named: "Observable").isEmpty)

        let expander = MacroExpander(registry: registry, host: MacroPluginHost(toolchain: toolchain))
        defer { expander.host.shutdown() }
        let source = """
        import Observation

        @Observable
        final class Counter {
            var count = 0
        }
        """
        let report = expander.expand(source: source, fileName: "obs.swift")
        XCTAssertTrue(report.expandedSource.contains("_$observationRegistrar"), report.expandedSource)
        XCTAssertTrue(report.expandedSource.contains("extension Counter: Observation.Observable") ||
                      report.expandedSource.contains("Observation.Observable"), report.expandedSource)
        // Nested: @Observable adds @ObservationTracked, which is expanded too.
        XCTAssertTrue(report.expansions.contains { $0.macroName == "ObservationTracked" && $0.isNested })
        XCTAssertTrue(report.expandedSource.contains("access(keyPath: \\.count)"), report.expandedSource)
        XCTAssertFalse(report.hasErrors, "\(report.diagnostics)")

        // Positions: user-written uses map to their lines; generated ones are flagged as nested.
        let positioned = expander.expand(source: source.replacingOccurrences(of: "    var count = 0", with: "    var count = 0\n    @ObservationIgnored var cache = 1"), fileName: "obs.swift")
        let ignored = positioned.expansions.filter { $0.macroName == "ObservationIgnored" }
        XCTAssertEqual(ignored.first { $0.attachedTo == "variable cache" }?.position?.line, 6)
        XCTAssertTrue(ignored.filter { $0.attachedTo != "variable cache" }.allSatisfy { $0.isNested })
        XCTAssertTrue(positioned.expansions.filter { $0.macroName == "Observable" }.allSatisfy { $0.position?.line == 3 })

        // Without the import the macro is not visible.
        let unimported = expander.expand(source: "@Observable final class C { var x = 0 }")
        XCTAssertTrue(unimported.expansions.isEmpty)

        // Cross-check against the real compiler.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftlens-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("obs.swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let compiler = try CompilerExpansionDump.run(files: [file.path], toolchain: toolchain)
        XCTAssertFalse(compiler.expansions.isEmpty, compiler.diagnostics)
        let problems = CompilerExpansionDump.verify(report: report, against: compiler.expansions)
        XCTAssertEqual(problems, [], "\nSwiftLens:\n\(report.expansions.map { "\($0.spelling) \($0.role): \($0.expandedSource)" }.joined(separator: "\n---\n"))\nCompiler:\n\(compiler.expansions.map { "\($0.macroName ?? "?") \(String(describing: $0.role)): \($0.expandedSource)" }.joined(separator: "\n---\n"))")
    }
}
