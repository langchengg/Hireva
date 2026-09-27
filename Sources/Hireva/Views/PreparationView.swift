import SwiftUI

struct PreparationView: View {
    @ObservedObject var appState: AppState
    @State private var url = ""
    @State private var brief: PublicRoleBrief?
    @State private var query = "SELECT c.name, SUM(o.amount) AS total\nFROM customers c LEFT JOIN orders o ON c.id = o.customer_id\nGROUP BY c.id, c.name ORDER BY c.id;"
    @State private var sql: SQLPracticeResult?
    @State private var code = ""
    @State private var worker: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var busy = false
    @State private var error = ""
    @State private var records: [PreparationRecord] = []
    @State private var selectedRecordText = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Prepare / Practical Tools · 准备与实操").font(.largeTitle.bold())
                Text("Networking and SQL run only from the buttons below. No personal materials are sent to a website.").foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if busy { ProgressView(); Button("Cancel") { cancel() } }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Public Company / JD Brief · 公开网页简报").font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://public-company.example/careers/role", text: $url)
                        Button("Fetch This Public URL (network) / 获取网页") { fetch() }.disabled(busy || appState.primaryHomeActionShouldStop)
                        Text("One HTTPS page plus robots.txt. Redirects, private addresses, browser credentials and IPv6-only sites are unsupported. Supply the final public URL. This is not a web-wide search.").font(.caption)
                        if let brief {
                            Text(brief.markdown).textSelection(.enabled)
                            Button("Use Source Excerpts as Job Description") {
                                appState.saveDocument(type: .jobDescription, title: brief.title, content: "Source: \(brief.url)\nRetrieved: \(brief.fetchedAt.formatted())\n" + brief.excerpts.map { "[\($0.location)] \($0.text)" }.joined(separator: "\n"))
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
                        TextEditor(text: $query).font(.body.monospaced()).frame(height: 140)
                        Button("Run SQL / 执行查询") { runSQL() }.disabled(busy)
                        if let sql {
                            Text("\(sql.executed ? "Executed" : "Rejected before execution") · \(sql.elapsedMS) ms · \(sql.rows.count) rows · \(sql.dataset)\(sql.truncated ? " · output capped" : "")")
                            if let message = sql.error { Text(message).foregroundStyle(.orange) }
                            ScrollView(.horizontal) {
                                Text(([sql.columns.joined(separator: " | ")] + sql.rows.map { $0.map { $0 ?? "NULL" }.joined(separator: " | ") }).joined(separator: "\n"))
                                    .font(.body.monospaced()).textSelection(.enabled)
                            }
                            if appState.practiceController.run != nil {
                                Button("Attach Result to Current Practice Question") { appState.practiceController.recordSQL(sql) }
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
                        TextEditor(text: $code).font(.body.monospaced()).frame(height: 140)
                        Text(StaticCodeReview.notes(code).joined(separator: "\n")).textSelection(.enabled)
                        Text("Code execution unavailable: no configured isolated runtime. Nothing runs on the host.").foregroundStyle(.orange)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Static code review")
                Text("Saved Results / Cache").font(.title2)
                if !appState.settings.saveTranscriptsLocally { Text("History is off; new query results and page snapshots are temporary.") }
                ForEach(records) { record in
                    HStack {
                        Button("\(record.kind) · \(record.createdAt.formatted())") { selectedRecordText = String(decoding: record.payload, as: UTF8.self) }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            do { try PreparationRepository(database: appState.database).delete(record.id); selectedRecordText = ""; refresh() } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                if !selectedRecordText.isEmpty { Text(selectedRecordText).font(.caption.monospaced()).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: 1050, alignment: .leading)
        }
        .onAppear { refresh() }
        .onDisappear { cancel() }
    }
    private func cancel() { operationID = UUID(); worker?.cancel(); worker = nil; busy = false }
    private func refresh() { records = (try? PreparationRepository(database: appState.database).records()) ?? [] }
    private func fetch() {
        cancel(); busy = true; error = ""
        let id = operationID; let text = url
        let consentTicket = appState.persistenceConsent.ticket()
        worker = Task {
            let work = Task.detached(priority: .utility) { try PublicRoleBriefService.fetch(text) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, operationID == id else { return }
                brief = result
                if appState.settings.saveTranscriptsLocally { try appState.persistenceConsent.write(ticket: consentTicket) { try PreparationRepository(database: appState.database).save(result, kind: "public-url-brief") } }
                refresh()
            } catch { if operationID == id, !Task.isCancelled { self.error = error.localizedDescription } }
            if operationID == id { busy = false }
        }
    }
    private func runSQL() {
        cancel(); busy = true; error = ""
        let id = operationID; let text = query
        let consentTicket = appState.persistenceConsent.ticket()
        worker = Task {
            let work = Task.detached(priority: .utility) { PracticeSQLService.run(text) }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, operationID == id else { return }
            sql = result; busy = false
            if appState.settings.saveTranscriptsLocally {
                do { try appState.persistenceConsent.write(ticket: consentTicket) { try PreparationRepository(database: appState.database).save(result, kind: "sql-execution") }; refresh() } catch { self.error = error.localizedDescription }
            }
        }
    }
}
