import SwiftUI

struct PrimaryButton: View {
    var title: String
    var systemImage: String
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 110)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isDisabled)
    }
}
