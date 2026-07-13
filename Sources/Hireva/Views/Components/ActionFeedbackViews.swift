import SwiftUI

struct ActionButton: View {
    @ObservedObject var appState: AppState
    var actionID: String
    var title: String
    var loadingTitle: String
    var successTitle: String? = nil
    var systemImage: String
    var role: ButtonRole? = nil
    var isProminent: Bool = false
    var controlSize: ControlSize = .regular
    var disabled: Bool = false
    var action: () -> Void

    private var isLoading: Bool {
        appState.isActionLoading(actionID)
    }

    private var displayTitle: String {
        if isLoading {
            return loadingTitle
        }
        if let feedback = appState.latestActionFeedback(for: actionID),
           feedback.kind == .success {
            return successTitle ?? feedback.title
        }
        return title
    }

    var body: some View {
        if isProminent {
            baseButton
                .buttonStyle(.borderedProminent)
                .controlSize(controlSize)
        } else {
            baseButton
                .buttonStyle(.bordered)
                .controlSize(controlSize)
        }
    }

    private var baseButton: some View {
        Button(role: role) {
            guard !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: buttonIcon)
                }
                Text(displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 92)
        }
        .disabled(disabled || isLoading)
        .help(displayTitle)
    }

    private var buttonIcon: String {
        guard let feedback = appState.latestActionFeedback(for: actionID) else {
            return systemImage
        }
        switch feedback.kind {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .info, .loading:
            return systemImage
        }
    }
}

struct ProgressButton: View {
    @ObservedObject var appState: AppState
    var actionID: String
    var title: String
    var loadingTitle: String
    var systemImage: String
    var progress: Double?
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ActionButton(
                appState: appState,
                actionID: actionID,
                title: title,
                loadingTitle: loadingTitle,
                systemImage: systemImage,
                isProminent: true,
                disabled: disabled,
                action: action
            )
            if appState.isActionLoading(actionID), let progress {
                ProgressView(value: progress, total: 1.0)
                    .frame(maxWidth: 260)
            }
        }
    }
}

struct InlineStatusBanner: View {
    var feedback: ActionFeedback?

    init(_ feedback: ActionFeedback?) {
        self.feedback = feedback
    }

    var body: some View {
        if let feedback {
            HStack(alignment: .top, spacing: 9) {
                if feedback.kind == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 1)
                } else {
                    Image(systemName: feedback.kind.systemImage)
                        .foregroundStyle(feedback.kind.tint)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(feedback.title)
                        .font(.caption.weight(.semibold))
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(feedback.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(feedback.kind.tint.opacity(0.24), lineWidth: 1)
            )
        }
    }
}

struct ToastBanner: View {
    var feedbacks: [ActionFeedback]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(feedbacks.suffix(3)) { feedback in
                HStack(spacing: 9) {
                    if feedback.kind == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: feedback.kind.systemImage)
                            .foregroundStyle(feedback.kind.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feedback.title)
                            .font(.caption.weight(.semibold))
                        Text(feedback.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: 320, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(feedback.kind.tint.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            }
        }
        .padding(18)
    }
}

extension ActionFeedbackKind {
    var tint: Color {
        switch self {
        case .info:
            return .blue
        case .loading:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .loading:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }
}
