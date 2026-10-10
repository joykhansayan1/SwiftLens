# SwiftLens

**A local-first Swift Macro Visualizer & SwiftUI Render Sandbox** — as a macOS menu-bar app, an Xcode Source Editor
Extension, and a command-line tool. Paste any Swift code and instantly see every macro expanded, its syntax tree, or
its previews rendered across light/dark, Dynamic Type, locales and devices. No Xcode project, no build, nothing leaves
your machine.

```text
$ swiftlens expand Model.swift --format diff          # @Observable, #Preview, #Predicate… with zero setup
$ swiftlens expand Usage.swift --plugin-path .build/debug --decls Sources/MyMacros
$ swiftlens tree Model.swift --at 12:9                # the node under the cursor + how to reach it in a macro
$ swiftlens render Card.swift --appearance light dark --dynamic-type large accessibility3
$ swiftlens live Card.swift                           # interactive preview window that hot-reloads on save
$ swiftlens lab MyMacro.swift --usage Example.swift   # macro playground: no package, no test target
```

## Why SwiftLens

Existing tools each solve a slice: Xcode expands one macro at a time and only after a successful build; the
compiler's `-dump-macro-expansions` is a debug dump; Swift AST Explorer is a website that may run a different
swift-syntax than you; swift-macro-testing needs a test target; Xcode Previews need a project; axe and ios-snap need
the iOS Simulator (axe: Apple Silicon only, no `#Preview` traits). See the full
[competitive analysis](docs/COMPETITIVE_ANALYSIS.md).

| | SwiftLens | Xcode Expand Macro | Swift AST Explorer | swift-macro-testing | Xcode Previews | axe |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Fully local / offline | ✅ | ✅ | ❌ web | ✅ | ✅ | ✅ |
| Expand **all** macros into one expanded file + diff | ✅ | ❌ one at a time | ❌ | per test | — | — |
| Works **without building** your project | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ |
| Nested expansions, timings, readable unique names | ✅ | partial | — | partial | — | — |
| Cross-check against the compiler (`--verify`) | ✅ | n/a | — | — | — | — |
| Macro diagnostics & fix-its mapped to your source | ✅ | ✅ | — | ✅ | — | — |
| Syntax tree from *your* swift-syntax + access paths | ✅ | — | tree only | — | — | — |
| Macro playground without a package | ✅ | — | — | — | — | — |
| Render SwiftUI from a pasted snippet | ✅ | — | — | — | ❌ project | ✅ sim |
| `#Preview(traits:)` and `@Previewable` | ✅ | — | — | — | ✅ | ❌ traits |
| Light/dark × Dynamic Type × locale × RTL × device matrix → PNG | ✅ one command | — | — | — | one dimension | — |
| Crash-isolated rendering | ✅ | — | — | — | ✅ | ✅ |
| Hot reload from any editor | ✅ | — | — | — | Xcode only | ✅ |
| Intel + Apple Silicon | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Menu bar + global shortcut + Xcode extension | ✅ | — | — | — | — | — |
| CLI / JSON for CI, macro tools on Linux | ✅ | — | — | ✅ | — | ✅ |

## Features

### Macro Visualizer
* **Zero-config Apple macros.** SwiftLens discovers macro declarations in the toolchain/SDK interfaces
  (Observation, SwiftUI `#Preview`, Foundation `#Predicate`/`#Expression`, Testing `@Test`/`#expect`, SwiftData `@Model`,
  `@TaskLocal`, `@DebugDescription`, …) and runs their plugins through the toolchain's `swift-plugin-server`.
* **Your macros**, as soon as the plugin is built: `--plugin path#Module`, `--plugin-path .build/debug` (finds
  `<Module>-tool` executables and `lib*.dylib` library plugins), `--decls` for the `macro` declarations.
* **Full-file expansion** spliced by swift-syntax's own `MacroSystem`: member, peer, accessor, member-attribute,
  extension, body, expression, declaration and code-item macros, including macros that expand to other macros.
* **Views**: expanded file, unified diff, or a list of every expansion with role, target declaration, plugin and
  timing. Readable unique names (`__continuation_1` rather than `$s…fMu_`).
* **`--verify`**: compares against `swiftc -Xfrontend -dump-macro-expansions`.
* **Diagnostics & fix-its** from macros, located in your source.

### Syntax Tree Explorer
* The exact tree your macro receives, with spans, trivia, missing tokens and parser diagnostics.
* **Access paths** for every node — the Swift expression that reaches it from the root, with `.as(T.self)` casts
  where swift-syntax type-erases (`DeclSyntax`, `ExprSyntax`, child-choice enums).
* Cursor sync in the app (breadcrumb + inspector), `--at line:col` in the CLI, JSON export.

### SwiftUI Render Sandbox (macOS)
* Renders `#Preview` (incl. `traits:` such as `.sizeThatFitsLayout`, `.fixedLayout`, `.landscapeLeft`, and
  `@Previewable` state), `PreviewProvider`s, or any default-constructible `View`.
* Variant matrix: appearance, Dynamic Type size, locale, layout direction, device canvas presets, pixel scale;
  AppKit (renders real controls) or `ImageRenderer` engines.
* User code runs in a separate **render agent** process with a watchdog — crashes and hangs are reported, never fatal.
* **Live window** for interaction, hot-reloading on save, reopening at the same frame.
* Content-addressed build cache; compiler errors point at your lines (via `#sourceLocation`).

### Macro Lab
Write a macro implementation and a usage side by side. SwiftLens discovers implementation types by protocol
(`StringifyMacro: ExpressionMacro` → `#stringify`, `AddIDMacro: MemberMacro` → `@AddID`), generates the plugin
package and entry point, builds incrementally and shows the expansion and the plugin's diagnostics.

### Everywhere you work
* **Menu-bar app** with a compact popover and a full window (editor + results), file watching (edit in Xcode,
  see results update), drag & drop, and the **⌥⌘L** global shortcut: copy code anywhere → SwiftLens opens with it.
* **Xcode Source Editor Extension** (*Editor ▸ SwiftLens*): Expand Macros / Show Syntax Tree / Render Previews in
  SwiftLens (unsaved buffer + cursor line are sent via `swiftlens://`), Convert PreviewProvider to `#Preview`,
  Wrap Selection in `#Preview`.
* **CLI** (`swiftlens`) with JSON output — use it in scripts, CI, or editors other than Xcode.

## Installation

Requirements: macOS 13+ with Xcode 16+ (or Swift 6.1+). The macro and syntax tools also run on Linux.

```bash
git clone https://github.com/joykhansayan1/SwiftLens.git && cd SwiftLens

# CLI
swift build -c release --product swiftlens
cp "$(swift build -c release --show-bin-path)/swiftlens" /usr/local/bin/

# Menu-bar app (ad-hoc signed) → dist/SwiftLens.app
scripts/build-app.sh
open dist/SwiftLens.app
```

### Xcode Source Editor Extension
Extensions must ship inside an app built by Xcode:

```bash
brew install xcodegen
xcodegen                       # generates SwiftLens.xcodeproj from project.yml
open SwiftLens.xcodeproj       # select your team, run the "SwiftLens" scheme once
```

Then enable it in **System Settings ▸ General ▸ Login Items & Extensions ▸ Xcode Source Editor**, restart Xcode, and
find the commands under **Editor ▸ SwiftLens** (bind shortcuts in Xcode ▸ Settings ▸ Key Bindings).

## Usage

### Expanding your own macros
```bash
swift build                                   # builds your macro plugin, e.g. .build/debug/MyMacros-tool
swiftlens expand Sources/App/Model.swift \
  --plugin-path .build/debug \
  --decls Sources/MyMacrosLibrary             # where your `public macro …` declarations live
```
In the app, add the same paths under **Settings ▸ Macro Plugins**. For Xcode builds use
`~/Library/Developer/Xcode/DerivedData/<Project>/Build/Products/Debug` as the plugin path.

Try the bundled demo:
```bash
swift build --product SwiftLensDemoMacros
swiftlens expand Examples/DemoMacros/Usage.swift \
  --plugin "$(swift build --show-bin-path)/SwiftLensDemoMacros#SwiftLensDemoMacros" \
  --decls Examples/DemoMacros/Declarations.swift --format diff
```

### Rendering
```bash
swiftlens previews Examples/Render/ProfileCard.swift          # what can be rendered
swiftlens render Examples/Render/ProfileCard.swift --appearance light dark --device "iPhone 16" --out shots
swiftlens render Card.swift -Xswiftc -F -Xswiftc ~/MyFrameworks  # views that import your frameworks
swiftlens live Examples/Render/ProfileCard.swift --preview Interactive
```

### Other commands
`swiftlens macros <file>` (which plugin implements each macro use), `swiftlens macros - --all` (every known macro),
`swiftlens migrate-previews <file> [--in-place]`, `swiftlens doctor` (toolchain, plugins, built-in macros).

## How it works

```text
            ┌──────────────── SwiftLens (app / CLI) ────────────────┐
 source ──▶ │ SwiftParser ─▶ MacroSystem ─▶ proxy macro types ──────┼──▶ plugin processes
            │      │              ▲            (one per role set)   │     • your macro executables
            │      │              └── re-parsed expansions ◀────────┼──── • swift-plugin-server + lib*Macros
            │      ▼                                                │
            │ SyntaxTreeBuilder (access paths) · SyntaxHighlighter  │
            │                                                       │
            │ PreviewExtractor ─▶ HarnessGenerator ─▶ swiftc dylib  │
            │                                     (cached by hash)  │
            └──────────────────────────────┬────────────────────────┘
                                           ▼
                    render agent (same binary, separate process): dlopen → NSHostingView /
                    ImageRenderer → PNG per variant · or a live, interactive window
```

* `SwiftLensCore` — parsing, syntax-tree model, access paths, macro-use scanning, diffing, highlighting.
* `SwiftLensMacroEngine` — plugin wire protocol, plugin host, macro registry/toolchain discovery, expander,
  compiler-dump parser/verifier, Macro Lab.
* `SwiftLensSandbox` — preview extraction, `@Previewable` lowering, harness generation, snippet compiler.
* `SwiftLensRenderer` — render agent, client with watchdog, live window, in-process live view loader.
* `SwiftLensUI` / `SwiftLensApp` — menu-bar app. `Extension/` — Xcode Source Editor Extension.

## Privacy
SwiftLens never makes network requests. Everything — parsing, plugin execution, compilation, rendering — happens in
local processes. (Macro Lab's first build fetches swift-syntax through SwiftPM unless you point
`SWIFTLENS_LAB_SWIFT_SYNTAX_PATH` at a local checkout.)

## Limitations & roadmap
* Rendering is macOS SwiftUI; iOS-only APIs won't compile. Planned: an iOS Simulator back end.
* Extension-macro conformances are filtered syntactically (`--verify` reports any difference from the compiler).
* Experimental preamble macros are not supported.
* Planned: per-expansion "jump to generated code" in Xcode, snapshot-diffing renders between commits.

## Development
```bash
swift build && swift test                       # 50+ tests; macro tests drive real plugin processes
SWIFTLENS_SLOW_TESTS=1 swift test --filter MacroLabTests   # builds a real plugin package
```
CI runs on Linux (Swift 6.1/6.2) and macOS (build, tests, real renders, crash-isolation check, Xcode project).

## License
Apache License 2.0 — see [LICENSE](LICENSE).
