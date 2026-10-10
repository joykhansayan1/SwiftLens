import SwiftLensRenderer

// The CLI binary doubles as the sandboxed render agent.
_ = RenderAgent.handleCommandLine()
SwiftLensCommand.main()
