import SwiftUI

struct PreparationView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var practice: PracticeController

    init(appState: AppState) {
        self.appState = appState
        self.practice = appState.practiceController
    }

    var body: some View {
        PreparationToolsView(
            state: appState.preparationState,
            liveCaptureActive: appState.primaryHomeActionShouldStop,
            historyEnabled: appState.settings.saveTranscriptsLocally,
            canAttachSQL: practice.run != nil,
            useBrief: { brief in
                appState.saveDocument(type: .jobDescription, title: brief.title,
                    content: "Source: \(brief.url)\nRetrieved: \(brief.fetchedAt.formatted())\n" +
                        brief.excerpts.map { "[\($0.location)] \($0.text)" }.joined(separator: "\n"))
            },
            attachSQL: { practice.recordSQL($0) }
        )
    }
}

private struct PreparationToolsView: View {
    @ObservedObject var state: PreparationState
    let liveCaptureActive: Bool
    let historyEnabled: Bool
    let canAttachSQL: Bool
    let useBrief: (PublicRoleBrief) -> Void
    let attachSQL: (SQLPracticeResult) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Prepare / Practical Tools · 准备与实操").font(.largeTitle.bold())
                Text("Networking and SQL run only from the buttons below. No personal materials are sent to a website.").foregroundStyle(.secondary)
                if !state.error.isEmpty { Text(state.error).foregroundStyle(.red).textSelection(.enabled) }
                if state.busy { ProgressView(); Button("Cancel") { state.cancel() } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Public Company / JD Brief · 公开网页简报").font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://public-company.example/careers/role", text: $state.url)
                        Button("Fetch This Public URL (network) / 获取网页") { state.fetch() }.disabled(state.busy || liveCaptureActive)
                        Text("One HTTPS page plus robots.txt. Redirects, private addresses, browser credentials and IPv6-only sites are unsupported. Supply the final public URL. This is not a web-wide search.").font(.caption)
                        if let brief = state.brief {
                            Text(brief.markdown).textSelection(.enabled)
                            Button("Use Source Excerpts as Job Description") {
                                useBrief(brief)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Public company and job description brief")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Isolated Read-only SQL · 独立只读 SQL").font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PracticeSQLService.schema).font(.caption).textSelection(.enabled)
                        TextEditor(text: $state.query).font(.body.monospaced()).frame(height: 140)
                        Button("Run SQL / 执行查询") { state.runSQL() }.disabled(state.busy)
                        if let sql = state.sql {
                            Text("\(sql.executed ? "Executed" : "Rejected before execution") · \(sql.elapsedMS) ms · \(sql.rows.count) rows · \(sql.dataset)\(sql.truncated ? " · output capped" : "")")
                            if let message = sql.error { Text(message).foregroundStyle(.orange) }
                            ScrollView(.horizontal) {
                                Text(([sql.columns.joined(separator: " | ")] + sql.rows.map { $0.map { $0 ?? "NULL" }.joined(separator: " | ") }).joined(separator: "\n"))
                                    .font(.body.monospaced()).textSelection(.enabled)
                            }
                            if canAttachSQL {
                                Button("Attach Result to Current Practice Question") { attachSQL(sql) }
                            }
                        } else { Text("Not executed / 未执行").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Isolated read-only SQL")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Code Review · 代码静态检查").font(.headline)
                    VStack(alignment: .leading) {
                        TextEditor(text: $state.code).font(.body.monospaced()).frame(height: 140)
                        Text(StaticCodeReview.notes(state.code).joined(separator: "\n")).textSelection(.enabled)
                        Text("Code execution unavailable: no configured isolated runtime. Nothing runs on the host.").foregroundStyle(.orange)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Static code review")
                Text("Saved Results / Cache").font(.title2)
                if !historyEnabled { Text("History is off; new query results and page snapshots are temporary.") }
                ForEach(state.records) { record in
                    HStack {
                        Button("\(record.kind) · \(record.createdAt.formatted())") { state.select(record) }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            state.delete(record)
                        }
                    }
                }
                if !state.selectedRecordText.isEmpty { Text(state.selectedRecordText).font(.caption.monospaced()).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: 1050, alignment: .leading)
        }
        .onAppear { state.refresh() }
        .onDisappear { state.cancel() }
    }
}
