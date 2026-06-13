// Maintains developer diagnostics for capture, generation, latency, and
// runtime health.
// Diagnostics may expose raw technical state such as generation IDs and ASR
// health, but normal product screens should translate those into human states.

import Foundation
import Combine
import SwiftUI

extension AppState {
    // MARK: - Main Thread Health

    public func startMainThreadHeartbeat() {
        mainThreadHeartbeatTask?.cancel()
        let now = Date()
        mainThreadHeartbeatAt = now
        lastHeartbeatTickAt = now
        mainThreadHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                let tick = Date()
                let previous = self.lastHeartbeatTickAt ?? tick
                let delay = max(0, Int((tick.timeIntervalSince(previous) - 0.5) * 1_000))
                self.mainThreadHeartbeatAt = tick
                self.mainThreadHeartbeatDelayMs = delay
                self.lastHeartbeatTickAt = tick
                if delay > 2_000 {
                    self.lastLongOperationName = "Main thread appears blocked"
                    self.lastLongOperationStartedAt = previous
                    print("[AppState] Main thread appears blocked: \(delay) ms")
                }
            }
        }
    }

    // MARK: - Active Operation Labels

    func markSQLiteOperation(_ operation: String) {
        lastSQLiteOperation = operation
        lastLongOperationName = operation
        lastLongOperationStartedAt = Date()
        updateActiveTaskSummary()
    }

    func markRAGOperation(_ operation: String) {
        lastRAGOperation = operation
        lastLongOperationName = operation
        lastLongOperationStartedAt = Date()
        updateActiveTaskSummary()
    }

    func markProviderOperation(_ operation: String) {
        lastProviderOperation = operation
        lastLongOperationName = operation
        lastLongOperationStartedAt = Date()
        updateActiveTaskSummary()
    }

    func updateActiveTaskSummary() {
        guard let activeGenerationID else {
            activeTaskSummary = "Idle"
            return
        }
        let shortGeneration = String(activeGenerationID.prefix(8))
        let question = activeQuestionID.map { String($0.prefix(8)) } ?? "none"
        activeTaskSummary = "generation=\(shortGeneration) question=\(question) state=\(generationUIState.displayName) fallbackWatchdog=\(fallbackWatchdogActive) stageB=\(stageBTaskActive) providerStream=\(providerStreamActive)"
    }

    func updateDiagnostics(_ mutate: (inout DeveloperDiagnostics) -> Void) {
        var next = diagnostics
        mutate(&next)
        diagnostics = next
    }

    // MARK: - Capture Events

    public func addCaptureEvent(
        name: String,
        stateBefore: String,
        stateAfter: String,
        reason: String,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        let event = CaptureEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            eventName: name,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            reason: reason,
            file: file.split(separator: "/").last.map(String.init) ?? file,
            function: function,
            line: line,
            systemCaptureRunning: systemCaptureRunning,
            micCaptureRunning: micCaptureRunning,
            lastSystemAudioBufferAt: lastSystemAudioBufferAt
        )
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recent20CaptureEvents.append(event)
            if self.recent20CaptureEvents.count > 20 {
                self.recent20CaptureEvents.removeFirst()
            }
            self.objectWillChange.send()
        }
    }
}
