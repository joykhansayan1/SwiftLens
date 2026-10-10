# Competitive analysis

SwiftLens sits between two families of tools: **macro inspection** (Xcode's *Expand Macro*, SourceKit-LSP,
Swift AST Explorer, swift-macro-testing, the compiler's `-dump-macro-expansions`) and **SwiftUI rendering outside
the Xcode canvas** (Xcode Previews, axe, ios-snap, InjectionIII / Inject). This document records what each one
does well, where it falls short, and the specific design decision SwiftLens makes in response.

Research snapshot: October 2026.

## Macro inspection

| | What it does well | Gaps SwiftLens targets |
|---|---|---|
| **Xcode › Editor › Expand Macro** | Exact compiler output, inline in the editor. | One macro at a time, inline only; requires the target to *build*; no diff, no history, no way to see nested expansions together; expansion lives in memory, nothing to copy as a whole file. |
| **`swiftc -Xfrontend -dump-macro-expansions`** | Ground truth for every expansion in a file. | Debug dump with mangled buffer names (`@__swiftmacro_3obs7Counter10ObservablefMm_.swift`) and mangled unique names; no positions; forum users note there is still *no tool that writes the fully expanded file*. |
| **SourceKit-LSP / VS Code "Expand Macro"** (GSoC 2024, Swift 6.1) | Peek view in VS Code. | Per-macro peek; needs an indexed build; VS Code only. |
| **Swift AST Explorer** (swift-ast-explorer.com) | Excellent tree browsing; great for learning swift-syntax. | Web-hosted (code leaves your machine unless self-hosted); its swift-syntax version can differ from yours (a forum thread documents a mismatch); does not expand macros; no "how do I reach this node" help. |
| **swift-macro-testing** (Point-Free) | Inline expansion/diagnostic/fix-it snapshots in tests, re-recording. | Lives in a test target: you need a macro package, a test, and a build cycle to see anything. |

### SwiftLens' answer

* **Drives the real macro plugins directly** over the compiler's plugin protocol (executables, or library plugins
  through the toolchain's `swift-plugin-server`). No project build: `@Observable`, `#Preview`, `#Predicate`,
  `@Test`, `@TaskLocal`, … work on any pasted snippet, and your own macros work as soon as their plugin is built.
* **Whole-file expansion** spliced by swift-syntax's own `MacroSystem` (through generated proxy macro types), with
  nested expansions, a unified diff, per-expansion timing, and readable unique names (`__Member_1` instead of
  `$s3obs…6MemberfMu_`).
* **`--verify`** re-expands with `swiftc -dump-macro-expansions` and diffs the two — the precision of the compiler
  with the ergonomics of a live tool. (In the test-suite, all 9 `@Observable` expansions match byte-for-byte modulo
  whitespace.)
* **Diagnostics and fix-its** from macros are mapped back to line:column in your source.
* **Syntax tree from the exact swift-syntax you link**, with a ready-to-paste *access path* for every node, e.g.
  `sourceFile.statements.first?.item.as(StructDeclSyntax.self)?.memberBlock.members.first?.decl.as(VariableDeclSyntax.self)`.
* **Macro Lab**: paste an implementation and a usage; SwiftLens generates the package/plugin entry point, builds
  incrementally (~5 s after the first build) and shows the expansion. No package, no test target.

## SwiftUI rendering outside the canvas

| | What it does well | Gaps SwiftLens targets |
|---|---|---|
| **Xcode Previews / canvas** | First-party, interactive, variants for a single dimension. | Needs an Xcode project and a building scheme; can't preview a pasted snippet; no batch export of a light/dark × Dynamic Type × locale matrix; slow restarts after edits to non-body code. |
| **axe** (k-kohey) | CLI + VS Code extension, hot reload via `@_dynamicReplacement`. | iOS Simulator only, **Apple Silicon only**, needs `idb_companion`; `#Preview(traits:)` **not supported**; stored-property edits force full rebuilds; occasionally incomplete frames. |
| **ios-snap** | Renders a SwiftUI expression to PNG from the CLI. | Goes through the iOS Simulator; snippet mode is an expression, not a file with previews. |
| **InjectionIII / InjectionNext / Inject** | Live code injection into a running app. | Requires app/project setup (`-interposable` linker flags, `@ObserveInjection`); not a scratchpad. |
| **Swift Playgrounds / `#Playground` (Xcode 26)** | Quick experiments. | Beta-era crashes reported; not a renderer/exporter; no variant matrix. |

### SwiftLens' answer

* **Any file, no project**: `#Preview` blocks (with `traits:` and `@Previewable`), `PreviewProvider`s, or — if
  there are none — any `View` that can be created with `init()`.
* **No PreviewsMacros dependency**: preview bodies are lowered into generated `View` structs, `@Previewable`
  becomes real `@State`, and `#sourceLocation` keeps compiler errors pointing at *your* lines.
* **Variant matrix in one call**: appearance × Dynamic Type × locale × layout direction × canvas preset, exported as
  PNGs (`swiftlens render … --appearance light dark --dynamic-type large accessibility3 --locale en ar --rtl`).
* **Crash isolation**: user code runs in a separate agent process with a watchdog; an `Index out of range` or an
  infinite loop becomes an error message, not a dead app.
* **Hot reload with any editor**: `swiftlens live File.swift` (or the app's Live Window) recompiles on save and
  reopens the interactive window at the same position — Intel and Apple Silicon.
* **Content-addressed build cache**: re-rendering unchanged code is instant.

## Everyday ergonomics

* **Menu-bar app** with a **global shortcut (⌥⌘L)**: copy code anywhere → see its expansion / tree / render.
* **Xcode Source Editor Extension**: *Expand Macros / Show Syntax Tree / Render Previews in SwiftLens* (unsaved
  buffer included), plus in-place *Convert PreviewProvider to #Preview* and *Wrap Selection in #Preview*.
* **CLI with JSON output** for scripts and CI; macro tooling also runs on **Linux**.
* **Local-first and open source** (Apache 2.0): no network access, no telemetry.

## Honest limitations

* Rendering uses **macOS SwiftUI**. iOS-only APIs (UIKit, `navigationBarTitleDisplayMode`, …) won't compile, and
  macOS does not scale system text styles with Dynamic Type (custom views reading `\.dynamicTypeSize` do react).
  An iOS-Simulator back end is on the roadmap.
* Macros are expanded syntactically, exactly like the compiler does, but SwiftLens decides extension
  `conformances:` from the declaration syntax; a type that conforms via a separate extension may still get the
  conformance. `--verify` catches such differences.
* Experimental *preamble* macros are not proxied.
