import SwiftUI

struct LoadingOverlay: View {
    var title: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 12, y: 6)
        }
    }
}
