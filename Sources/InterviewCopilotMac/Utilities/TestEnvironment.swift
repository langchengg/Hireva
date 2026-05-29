import Foundation

/// Returns true if the process is running under unit tests, XCTest runners, or Antigravity automation tools.
public func isRunningUnderTestOrAutomation() -> Bool {
    if NSClassFromString("XCTestCase") != nil {
        return true
    }
    let env = ProcessInfo.processInfo.environment
    if env["XCTestBundlePath"] != nil || env["XCS"] != nil || env["ANTIGRAVITY"] != nil {
        return true
    }
    let processName = ProcessInfo.processInfo.processName
    if processName.contains("xctest") || processName.contains("swift-test") {
        return true
    }
    return false
}
