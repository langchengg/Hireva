import SwiftUI

/// An editable rehearsal draft, deliberately never inserted into ProfileEvidence.
struct StoryDraft: Codable, Identifiable {
    var id = UUID().uuidString
    var candidateProfileID: String
    var sourceDocumentIDs: [String]
    var evidenceIDs: [String]
    var title: String
    var structure = "Situation → Action → Result → Reflection"
    var situation = ""
    var action = ""
    var result = ""
    var reflection = ""
}

struct StoryCardsView: View {
    @ObservedObject var appState: AppState
    let profile: CandidateProfile
    @State private var drafts: [StoryDraft] = []
    @State private var status = ""
    var body: some View {
        DisclosureGroup("Project / Behavioral Story Drafts · 故事卡") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drafts rehearse supported facts. Editing or saving a story does not confirm facts; use Confirm Evidence above. Leave missing results and metrics blank.").font(.caption)
                Button("Create From Selected Profile Evidence") {
                    let evidence = profile.allEvidence.filter { $0.isUsable && [.project, .experience, .achievement].contains($0.evidenceType) }
                    drafts.append(StoryDraft(candidateProfileID: profile.id, sourceDocumentIDs: Array(Set(evidence.compactMap(\.sourceDocumentID))), evidenceIDs: evidence.map(\.id), title: "New story", action: evidence.map(\.statement).joined(separator: "\n")))
                }
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading) {
                        TextField("Title", text: $draft.title)
                        Picker("Answer structure", selection: $draft.structure) {
                            Text("STAR + reflection").tag("Situation → Action → Result → Reflection")
                            Text("Problem / choices / evidence").tag("Problem → Choices → Evidence → Limits")
                            Text("Direct / supporting evidence").tag("Direct answer → Evidence → Caveats")
                        }
                        Text("Situation / problem").font(.caption)
                        TextEditor(text: $draft.situation).frame(height: 60)
                        Text("Personal action / choices (check team attribution)").font(.caption)
                        TextEditor(text: $draft.action).frame(height: 100)
                        Text("Result / evidence — blank when missing").font(.caption)
                        TextEditor(text: $draft.result).frame(height: 60)
                        Text("Reflection / limits").font(.caption)
                        TextEditor(text: $draft.reflection).frame(height: 60)
                        DisclosureGroup("Source evidence") {
                            ForEach(draft.evidenceIDs, id: \.self) { id in
                                if let source = profile.allEvidence.first(where: { $0.id == id }) {
                                    Text("[\(id.prefix(8))] \(source.statement)\nSource: \(source.sourceSpan ?? "location unavailable")").textSelection(.enabled)
                                } else { Text("Source deleted or no longer in this profile") }
                            }
                        }
                        HStack {
                            Button("Save Draft (not confirmed facts)") {
                                do { try PreparationRepository(database: appState.database).saveStory(draft); status = "Draft saved separately from personal facts." }
                                catch { status = error.localizedDescription }
                            }.disabled(!appState.settings.saveTranscriptsLocally)
                            Button("Delete Draft", role: .destructive) {
                                do { try PreparationRepository(database: appState.database).delete(draft.id); drafts.removeAll { $0.id == draft.id } }
                                catch { status = error.localizedDescription }
                            }
                        }
                    }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(status).font(.caption)
            }
        }.onAppear {
            drafts = ((try? PreparationRepository(database: appState.database).records()) ?? []).filter { $0.kind == "story-draft" }.compactMap { try? JSONDecoder().decode(StoryDraft.self, from: $0.payload) }.filter { $0.candidateProfileID == profile.id }
        }
    }
}
