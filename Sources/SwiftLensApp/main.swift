#if os(macOS)
import SwiftLensRenderer
import SwiftLensUI

// The app binary doubles as the sandboxed render agent (launched with --swiftlens-render-agent).
_ = RenderAgent.handleCommandLine()
SwiftLensMainApp.main()
#else
print("The SwiftLens app requires macOS. On this platform use the `swiftlens` command-line tool.")
#endif
