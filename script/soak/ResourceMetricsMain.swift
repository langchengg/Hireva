import Foundation
import Darwin

@main
struct ResourceMetricsMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print(SoakResourceMetricsCLI.helpText)
            return
        }

        do {
            let configuration = try SoakResourceMetricsCLI.parse(arguments: arguments)
            let summary = try SoakResourceMetricsCollector(configuration: configuration).run()
            print("samples=\(summary.sampleCount)")
            print("expected_samples=\(summary.expectedSampleCount)")
            print("exact_target_samples=\(summary.exactTargetSampleCount)")
            print("collection_errors=\(summary.collectionErrorCount)")
            print("rotations=\(summary.rotationCount)")
            print("cleanups=\(summary.cleanupCount)")
            print("metrics_csv=\(configuration.outputURL.path)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(2)
        }
    }
}
