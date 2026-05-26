import SwiftUI

struct SuggestionCardView: View {
    var card: SuggestionCard?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggestion Card")
                .font(.headline)
            if let card {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(card.strategy)
                                .font(.title2.weight(.bold))
                            Spacer()
                            if let confidence = card.confidence {
                                StatusPill(title: "\(Int(confidence * 100))%", systemImage: "gauge.medium", tint: confidence >= 0.75 ? .green : .orange)
                            }
                        }
                        Text(card.sayFirst)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            StatusPill(
                                title: "\(card.providerName ?? "Provider"): \(card.modelName)",
                                systemImage: card.isLocal ? "desktopcomputer" : "cloud",
                                tint: card.isLocal ? .green : .blue
                            )
                            if let latency = card.latencyMS {
                                StatusPill(title: "\(latency) ms", systemImage: "timer", tint: .secondary)
                            }
                        }

                        section("Key Points", icon: "list.bullet", items: card.keyPoints)
                        section("Follow-up Ready", icon: "arrowshape.turn.up.right", items: card.followUpReady)

                        if !card.evidenceUsed.isEmpty {
                            section("Evidence Used", icon: "quote.bubble", items: card.evidenceUsed)
                        }

                        HStack(spacing: 8) {
                            if let risk = card.riskLevel {
                                StatusPill(title: "Risk \(risk.rawValue.capitalized)", systemImage: "exclamationmark.triangle", tint: risk == .low ? .green : (risk == .medium ? .orange : .red))
                            }
                            if let caution = card.caution, !caution.isEmpty {
                                Text(caution)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(18)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else {
                EmptyStateView(title: "No suggestion yet", message: "Start Listening. Automatic detection will generate a concise card when a complete question is heard.", systemImage: "sparkles")
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func section(_ title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.top, 3)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
