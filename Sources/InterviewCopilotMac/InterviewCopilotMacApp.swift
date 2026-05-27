import AppKit
import SwiftUI

public struct InterviewCopilotMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.bootstrap()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .frame(minWidth: 1_120, minHeight: 720)
                .background(WindowMinSizeEnforcer(minWidth: 1120, minHeight: 720))
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appSettings) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Assistant") {
                Button {
                    appState.showFloatingAssistant()
                } label: {
                    Label("Show Floating Assistant", systemImage: "macwindow.badge.plus")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(appState: appState)
                .frame(width: 720, height: 640)
        }
    }
}

struct WindowMinSizeEnforcer: NSViewRepresentable {
    var minWidth: CGFloat
    var minHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window, !(window is NSPanel) {
                window.minSize = NSSize(width: minWidth, height: minHeight)
                window.setFrame(NSRect(x: 20, y: 100, width: 1120, height: 720), display: true, animate: false)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, !(window is NSPanel) {
            window.minSize = NSSize(width: minWidth, height: minHeight)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
