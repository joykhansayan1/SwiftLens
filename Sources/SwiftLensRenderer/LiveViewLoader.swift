#if os(macOS)
import AppKit
import Foundation
import SwiftLensSandbox

/// Loads a compiled preview library into *this* process and returns an interactive `NSView`.
///
/// Faster than the live-window agent (no process launch) but not crash-isolated; the app uses it only when
/// "In-process live canvas" is enabled. Each compilation has a unique module name, so successive versions can
/// be loaded side by side; handles are intentionally never closed (unloading Swift code is unsafe).
@MainActor
public enum LiveViewLoader {
    private static var handles: [String: UnsafeMutableRawPointer] = [:]

    public static func makeView(libraryPath: String, previewIndex: Int, variant: RenderVariant) throws -> NSView {
        let handle: UnsafeMutableRawPointer
        if let existing = handles[libraryPath] {
            handle = existing
        } else {
            guard let opened = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
                throw RenderAgentError.loadFailed(String(cString: dlerror()))
            }
            handles[libraryPath] = opened
            handle = opened
        }
        guard let symbol = dlsym(handle, HarnessGenerator.Symbol.makeNSView) else {
            throw RenderAgentError.missingSymbol(HarnessGenerator.Symbol.makeNSView)
        }
        typealias MakeView = @convention(c) (Int32, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
        let make = unsafeBitCast(symbol, to: MakeView.self)
        let config = String(decoding: (try? JSONEncoder().encode(variant)) ?? Data("{}".utf8), as: UTF8.self)
        guard let pointer = config.withCString({ make(Int32(previewIndex), $0) }) else {
            throw RenderAgentError.missingSymbol(HarnessGenerator.Symbol.makeNSView)
        }
        return Unmanaged<NSView>.fromOpaque(pointer).takeRetainedValue()
    }
}
#endif
