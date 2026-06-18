import AppKit
import SwiftUI

@MainActor
final class FloatingAssistantPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingAssistantPanelController()

    private var panel: NSPanel?
    private weak var appState: AppState?

    private override init() {
        super.init()
    }

    func show(appState: AppState) {
        self.appState = appState

        guard !Self.isRunningInTestBundle else {
            panel?.orderOut(nil)
            appState.isFloatingAssistantVisible = true
            return
        }

        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: FloatingAssistantView(appState: appState))
        self.panel = panel
        panel.orderFrontRegardless()
        appState.isFloatingAssistantVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        appState?.isFloatingAssistantVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        appState?.isFloatingAssistantVisible = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 220, y: 220, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Interview Copilot"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 340, height: 300)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.delegate = self
        panel.setFrameAutosaveName("InterviewCopilotFloatingAssistant")
        
        // Translucency window modifications
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        
        return panel
    }

    private static var isRunningInTestBundle: Bool {
        let bundlePath = Bundle.main.bundlePath
        return bundlePath.hasSuffix(".xctest") || bundlePath.contains("PackageTests.xctest")
    }
}
