import SwiftUI

struct RAGDiagnosticsView: View {
    @ObservedObject var appState: AppState
    @State private var expandedChunkIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("RAG Diagnostics", systemImage: "doc.text.magnifyingglass")
                .font(.title2.weight(.bold))
            Text("Ground-truth retrieval stats for CV & Resume chunks, keyword scoring, budget trimming, and prompt injection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Chunk Inventory Summary
            HStack(spacing: 15) {
                inventoryCard(title: "CV / Resume Chunks", count: appState.diagnostics.storedCVChunkCount, icon: "doc.text.fill", color: .blue)
                inventoryCard(title: "Job Description Chunks", count: appState.diagnostics.storedJDChunkCount, icon: "briefcase.fill", color: .purple)
            }

            if let trace = appState.lastRetrievalTrace {
                traceTelemetryCard(trace: trace)
                
                // CV Chunks List
                chunkSection(title: "CV / Resume Source Attribution", 
                             ranked: trace.rankedCVChunks, 
                             wordBudget: trace.cvWordBudget, 
                             wordsUsed: trace.cvWordsUsed)
                
                // JD Chunks List
                chunkSection(title: "Job Description Source Attribution", 
                             ranked: trace.rankedJDChunks, 
                             wordBudget: trace.jdWordBudget, 
                             wordsUsed: trace.jdWordsUsed)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No Retrieval Trace Generated Yet")
                        .font(.headline)
                    Text("Retrieved chunks and attribution will appear here after capturing a question and generating an AI suggestion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            // RAG Clean Index Card
            VStack(alignment: .leading, spacing: 10) {
                Text("Clean Index Management")
                    .font(.headline)
                Text("If your CV or Job Description documents contain LaTeX formatting or raw preambles, click below to sanitize all document content and recreate RAG chunks. Cloud embeddings are rebuilt when configured; otherwise keyword RAG remains available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if appState.isRebuildingEmbeddings {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: appState.rebuildProgress, total: 1.0)
                        HStack {
                            Text("Rebuilding Index: \(Int(appState.rebuildProgress * 100))% complete")
                                .font(.caption)
                            Spacer()
                            Button("Cancel") {
                                appState.cancelEmbeddingRebuild()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    ActionButton(
                        appState: appState,
                        actionID: ActionID.rebuildCleanRAG,
                        title: "Rebuild Clean RAG Index",
                        loadingTitle: "Rebuilding...",
                        successTitle: "Index rebuilt",
                        systemImage: "arrow.triangle.2.circlepath",
                        isProminent: true
                    ) {
                        appState.rebuildCleanRAGIndex()
                    }
                }

                InlineStatusBanner(appState.latestActionFeedback(matching: [ActionID.rebuildCleanRAG, ActionID.rebuildEmbeddings]))
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inventoryCard(title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(count) stored chunks")
                    .font(.headline.weight(.semibold))
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func traceTelemetryCard(trace: RetrievalTrace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last Retrieval Telemetry")
                .font(.headline)
            
            Divider()

            Group {
                row("Captured Query", trace.query.isEmpty ? "[Empty]" : trace.query)
                row("Detected Intent", trace.intent ?? "technical")
                row("Latency (Total)", String(format: "%.2f ms", trace.retrievalLatencyMS))
                row("RAG Retrieval Mode", trace.retrievalMode ?? "keywordOnly")
                if let provider = trace.embeddingProvider {
                    row("Embedding Provider", provider)
                }
                if let model = trace.embeddingModel {
                    row("Embedding Model", model)
                }
                if let coverage = trace.embeddingCoveragePercent {
                    row("Embedding Coverage", String(format: "%.1f%%", coverage))
                }
                if let stale = appState.embeddingCoverage?.staleChunksCount {
                    row("Stale Chunks", "\(stale) chunks")
                }
                if let qLatency = trace.queryEmbeddingLatencyMS {
                    row("Query Embedding Latency", String(format: "%.2f ms", qLatency))
                }
                if let vLatency = trace.vectorSearchLatencyMS {
                    row("Vector Search Latency", String(format: "%.2f ms", vLatency))
                }
                row("Hybrid Weights", String(format: "Semantic: %.1f, Keyword: %.1f", trace.hybridSemanticWeight, trace.hybridKeywordWeight))
                if let fallback = trace.fallbackReason {
                    row("Fallback Reason", fallback)
                }
            }

            if !trace.embeddingWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Embedding Warnings")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    ForEach(trace.embeddingWarnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                Text("Fallback State:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if trace.emptyQueryFallbackUsed {
                    StatusPill(title: "Empty Query Fallback", systemImage: "exclamationmark.triangle", tint: .orange)
                } else {
                    StatusPill(title: "Query Valid", systemImage: "checkmark.circle", tint: .gray)
                }

                if trace.zeroScoreFallbackUsed {
                    StatusPill(title: "Zero Score Fallback", systemImage: "questionmark.circle", tint: .yellow)
                } else {
                    StatusPill(title: "Non-Zero Matches", systemImage: "sparkles", tint: .green)
                }
            }
            .padding(.top, 4)

            Divider()

            VStack(spacing: 8) {
                budgetProgressRow(title: "CV Word Budget Used", used: trace.cvWordsUsed, budget: trace.cvWordBudget)
                budgetProgressRow(title: "JD Word Budget Used", used: trace.jdWordsUsed, budget: trace.jdWordBudget)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func budgetProgressRow(title: String, used: Int, budget: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(used) / \(budget) words")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: Double(used), total: Double(max(budget, 1)))
                .tint(used > budget ? .red : (used == 0 ? .gray : .blue))
        }
    }

    private func chunkSection(title: String, ranked: [RetrievedChunk], wordBudget: Int, wordsUsed: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(ranked.count) candidates ranked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if ranked.isEmpty {
                Text("No source chunks found for this document type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(ranked) { chunk in
                        chunkRow(chunk: chunk)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func chunkRow(chunk: RetrievedChunk) -> some View {
        let isExpanded = expandedChunkIDs.contains(chunk.id)
        
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedChunkIDs.remove(chunk.id)
                    } else {
                        expandedChunkIDs.insert(chunk.id)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Rank #\(chunk.rank)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(chunk.isIncludedInPrompt ? .blue.opacity(0.2) : .gray.opacity(0.2))
                                .foregroundStyle(chunk.isIncludedInPrompt ? .blue : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Text("Score: \(String(format: "%.1f", chunk.score))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            
                            if let section = chunk.sectionTitle {
                                Text("Section: \(section)")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                                    .lineLimit(1)
                            }
                        }

                        Text(chunk.contentPreview + (chunk.fullContent.count > chunk.contentPreview.count ? "..." : ""))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(isExpanded ? nil : 2)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        if chunk.isIncludedInPrompt {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Text("Sent")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Omitted")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Content:")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        
                        ScrollView {
                            Text(chunk.fullContent)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(maxHeight: 200)
                    }

                    if !chunk.keywords.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extracted Keywords:")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(chunk.keywords, id: \.self) { kw in
                                        Text(kw)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.secondary.opacity(0.2), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        labelVal(label: "Overlap Keywords", val: "\(chunk.keywordOverlapCount)")
                        labelVal(label: "Overlap Content Tokens", val: "\(chunk.contentOverlapCount)")
                        if let wc = chunk.wordCount {
                            labelVal(label: "Words Count", val: "\(wc)")
                        }
                    }
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Semantic Score: \(chunk.semanticScore.map { String(format: "%.4f", $0) } ?? "nil")")
                            .font(.caption)
                            .foregroundStyle(chunk.semanticScore == nil ? .orange : .blue)
                        
                        Text("Keyword Score Normalized: \(chunk.keywordScoreNormalized.map { String(format: "%.4f", $0) } ?? "nil")")
                            .font(.caption)
                            .foregroundStyle(chunk.keywordScoreNormalized == nil ? .orange : .purple)
                        
                        Text("Final Hybrid Score: \(chunk.finalHybridScore.map { String(format: "%.4f", $0) } ?? "nil")")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(chunk.finalHybridScore == nil ? .orange : .green)
                        
                        if chunk.semanticScore == nil && chunk.retrievalMode == "hybrid" {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption2)
                                Text("Warning: Missing embedding or semantic score. Falling back.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(6)
                    .background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func labelVal(label: String, val: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(val)
                .font(.caption2.weight(.bold))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .frame(alignment: .leading)
            Spacer()
        }
        .font(.subheadline)
    }
}
