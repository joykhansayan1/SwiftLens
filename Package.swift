// swift-tools-version: 5.10
//
// SwiftLens — a local-first Swift Macro Visualizer & SwiftUI Render Sandbox.
//
// Layout:
//   SwiftLensCore        Parsing, syntax-tree model, macro usage scanning, text diffing (cross-platform)
//   SwiftLensMacroEngine Compiler-plugin host, macro registry, full-file expansion, compiler dump parsing,
//                        Macro Lab (cross-platform)
//   SwiftLensSandbox     #Preview / PreviewProvider extraction, @Previewable lowering, render-harness
//                        generation, snippet compilation (code generation is cross-platform)
//   SwiftLensRenderer    Out-of-process / in-process SwiftUI rendering (macOS only; empty elsewhere)
//   SwiftLensUI          The SwiftUI user interface shared by the menu-bar app and the Xcode-extension host
//   SwiftLensApp         Menu-bar app executable (macOS)
//   swiftlens            Command-line interface (cross-platform; rendering needs macOS)

import PackageDescription

let package = Package(
    name: "SwiftLens",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SwiftLensCore", targets: ["SwiftLensCore"]),
        .library(name: "SwiftLensMacroEngine", targets: ["SwiftLensMacroEngine"]),
        .library(name: "SwiftLensSandbox", targets: ["SwiftLensSandbox"]),
        .library(name: "SwiftLensRenderer", targets: ["SwiftLensRenderer"]),
        .library(name: "SwiftLensUI", targets: ["SwiftLensUI"]),
        .executable(name: "swiftlens", targets: ["swiftlens"]),
        .executable(name: "SwiftLensApp", targets: ["SwiftLensApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftLensCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftIDEUtils", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftLensMacroEngine",
            dependencies: [
                "SwiftLensCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftLensSandbox",
            dependencies: [
                "SwiftLensCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "SwiftLensRenderer",
            dependencies: ["SwiftLensCore", "SwiftLensSandbox"]
        ),
        .target(
            name: "SwiftLensUI",
            dependencies: ["SwiftLensCore", "SwiftLensMacroEngine", "SwiftLensSandbox", "SwiftLensRenderer"]
        ),
        .executableTarget(
            name: "swiftlens",
            dependencies: [
                "SwiftLensCore",
                "SwiftLensMacroEngine",
                "SwiftLensSandbox",
                "SwiftLensRenderer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "SwiftLensApp",
            dependencies: ["SwiftLensUI", "SwiftLensRenderer"]
        ),

        // A tiny compiler-plugin executable with sample macros. It is used by the test-suite to exercise the
        // plugin host end-to-end, and doubles as a demo plugin for the README walkthrough.
        .executableTarget(
            name: "SwiftLensDemoMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            path: "Examples/DemoMacros/Sources/SwiftLensDemoMacros"
        ),

        .testTarget(name: "SwiftLensCoreTests", dependencies: ["SwiftLensCore"]),
        .testTarget(
            name: "SwiftLensMacroEngineTests",
            dependencies: ["SwiftLensMacroEngine", "SwiftLensDemoMacros"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SwiftLensSandboxTests", dependencies: ["SwiftLensSandbox", "SwiftLensRenderer"]),
    ]
)
