import Foundation
import os

enum AppLogger {
    static let subsystem = "com.langcheng.InterviewCopilotMac"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}
