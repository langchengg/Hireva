import SwiftUI

struct StatusPill: View {
    var title: String
    var compactTitle: String? = nil
    var systemImage: String
    var tint: Color
    var isCompact: Bool = false

    var body: some View {
        Label(isCompact ? (compactTitle ?? title) : title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .frame(minWidth: isCompact ? 100 : 140, maxWidth: 240, alignment: .leading)
            .background(tint.opacity(0.12), in: Capsule())
            .accessibilityLabel(title)
    }
}
