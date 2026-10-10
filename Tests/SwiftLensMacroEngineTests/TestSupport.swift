import Foundation
import XCTest

enum TestSupport {
    /// Directory containing the built products (`.build/debug`), where the demo plugin executable lives.
    static var productsDirectory: URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        #endif
        return Bundle.main.bundleURL
    }

    static var demoPluginPath: String? {
        let candidates = [
            productsDirectory.appendingPathComponent("SwiftLensDemoMacros").path,
            productsDirectory.appendingPathComponent("SwiftLensDemoMacros-tool").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
