import SwiftUI

struct BuildIdentityCardView: View {
    let identity: BuildIdentity
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label("Build Identity", systemImage: identity.hasIdentityWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(identity.hasIdentityWarning ? .orange : .primary)
                Spacer()
                StatusPill(
                    title: identity.isReleaseBuild ? "release build" : "development build",
                    systemImage: identity.hasValidReleaseMetadata ? "checkmark.circle" : "exclamationmark.triangle",
                    tint: identity.hasValidReleaseMetadata ? .green : .orange
                )
            }

            if let warning = identity.identityWarning {
                Text(warning)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                buildRow("App bundle path", identity.bundlePath)
                buildRow("Bundle identifier", identity.bundleIdentifier)
                buildRow("Executable name", identity.executableName)
                buildRow("Bundle name", identity.bundleName)
                buildRow("Build timestamp", identity.buildTimestampUTC)
                buildRow("Git commit", identity.gitCommitHash)
                buildRow("Source branch", identity.gitBranch)
                buildRow("Git tree state", identity.gitTreeState)
                buildRow("Build configuration", identity.buildConfiguration)
                buildRow("Runtime mode", identity.runtimeMode)
                buildRow("Signing mode", identity.signingMode)
                buildRow("Distribution build", identity.distributionBuild ? "yes" : "no")
                if !compact {
                    if identity.hasExplicitDevelopmentPaths {
                        buildRow("Source root", identity.sourceRoot)
                        buildRow("Expected bundle path", identity.expectedBundlePath)
                    }
                    buildRow("Executable path", identity.executablePath)
                    buildRow("Executable timestamp", identity.executableModifiedDisplay)
                    buildRow("Info.plist timestamp", identity.infoPlistModifiedDisplay)
                    if identity.hasExplicitDevelopmentPaths {
                        buildRow("Latest source timestamp", identity.latestSourceModifiedDisplay)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func buildRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(compact ? 2 : 3)
                .textSelection(.enabled)
        }
    }
}
