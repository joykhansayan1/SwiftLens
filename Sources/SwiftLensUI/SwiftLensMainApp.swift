#if os(macOS)
import AppKit
import SwiftUI

final class SwiftLensAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon unless the main window is open (bundles also set LSUIElement).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The SwiftLens app: a menu-bar extra plus a full window, sharing one ``AppModel``.
public struct SwiftLensMainApp: App {
    @NSApplicationDelegateAdaptor(SwiftLensAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("SwiftLens", id: "main") {
            MainWindowView(model: model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .handlesExternalEvents(matching: ["swiftlens"])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
                Button("Paste Code from Clipboard") { model.loadFromClipboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Lens") {
                ForEach(Array(LensMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.title) { model.mode = mode }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu bar icon. It is always alive, so it is where `openWindow` and the global shortcut get wired up.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var hotKey: GlobalHotKey?

    var body: some View {
        Image(systemName: model.isExpanding || model.isRendering ? "eye.circle.fill" : "eye.circle")
            .onAppear(perform: configure)
            .onChange(of: model.settings.hotKeyEnabled) { _ in configure() }
    }

    private func configure() {
        model.openMainWindow = {
            openWindow(id: "main")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.settings.hotKeyEnabled {
            if hotKey == nil { hotKey = GlobalHotKey() }
            GlobalHotKey.action = {
                model.loadFromClipboard()
                model.openMainWindow?()
            }
        } else {
            hotKey = nil
            GlobalHotKey.action = nil
        }
    }
}
#endif
