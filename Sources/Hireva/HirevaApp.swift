import AppKit
import SwiftUI

public struct HirevaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.bootstrap()

    public init() {}

    public var body: some Scene {
        let state = appState
        let _ = appDelegate.configureShutdown(
            operation: { [weak state] in
                let applicationStopped = await state?.shutdownResources() ?? true
                let metadataStopped = await AudioDeviceManager.shared.shutdown()
                return applicationStopped && metadataStopped
            },
            reportPending: { [weak state] in state?.showError("Resource cleanup has not finished successfully. Quit again after cleanup finishes.") }
        )
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shutdownOperation: (@MainActor () async -> Bool)?
    private var reportPending: @MainActor () -> Void = {}
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var deadlineID: UUID?
    private var cleanupResult: Bool?
    private var replyPending = false
    private let delayProvider: any DelayProvider
    private let reply: @MainActor (Bool) -> Void

    override init() {
        delayProvider = RealDelayProvider()
        reply = { NSApp.reply(toApplicationShouldTerminate: $0) }
        super.init()
    }

    init(delayProvider: any DelayProvider, reply: @escaping @MainActor (Bool) -> Void) {
        self.delayProvider = delayProvider
        self.reply = reply
        super.init()
    }

    func configureShutdown(operation: @escaping @MainActor () async -> Bool,
        reportPending: @escaping @MainActor () -> Void) {
        guard cleanupTask == nil, cleanupResult == nil else { return }
        shutdownOperation = operation
        self.reportPending = reportPending
    }

    var hasPendingCleanup: Bool { cleanupTask != nil }
    var ownedDeadlineTaskForTesting: Task<Void, Never>? { deadlineTask }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination()
    }

    /// AppKit owns the pending quit reply. A deadline cancels that reply, while
    /// this delegate retains cleanup until resources actually finish stopping.
    func requestTermination() -> NSApplication.TerminateReply {
        if cleanupTask == nil {
            if cleanupResult == true { return .terminateNow }
            // A failed stop is not permanent success or a permanent veto.
            // A later explicit quit retries the same closed resource owners.
            if cleanupResult == false { cleanupResult = nil }
        }
        guard let shutdownOperation else { return .terminateNow }
        guard !replyPending else { return .terminateLater }
        replyPending = true
        if cleanupTask == nil {
            cleanupTask = Task { [self] in
                let result = await shutdownOperation()
                // Freeze resource resolution before suspension. A new quit can
                // join this result, but must not install another timer for it.
                cleanupResult = result
                let deadline = deadlineTask
                deadline?.cancel()
                await deadline?.value
                // Retire before invoking callbacks: a synchronous reply may
                // immediately start a separate retry after this failed attempt.
                cleanupTask = nil
                if replyPending {
                    replyPending = false
                    reply(result)
                    if !result { reportPending() }
                }
            }
        }
        if cleanupResult == nil {
            let id = UUID()
            deadlineID = id
            deadlineTask = Task { [self] in
                defer {
                    if deadlineID == id { deadlineID = nil; deadlineTask = nil }
                }
                do { try await delayProvider.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard deadlineID == id, replyPending, cleanupResult == nil else { return }
                replyPending = false
                reply(false)
                reportPending()
            }
        }
        return .terminateLater
    }

    func finishPendingCleanup() async {
        while cleanupTask != nil || deadlineTask != nil {
            let cleanup = cleanupTask, deadline = deadlineTask
            await cleanup?.value
            await deadline?.value
        }
    }
}
