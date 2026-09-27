import SwiftUI
import UniformTypeIdentifiers
import FSRS
import AppKit

struct PracticeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: PracticeController
    @State private var kind: InterviewTaskKind = .systemDesign
    @State private var language = "en"
    @State private var explanationLanguage = "en"
    @State private var question = InterviewTaskKind.systemDesign.starter(chinese: false)
    @State private var rubric = InterviewTaskKind.systemDesign.criteria.joined(separator: "\n")
    @State private var followUps = 2
    @State private var importing = false
    @State private var revealedReviews = Set<String>()
    init(appState: AppState) {
        self.appState = appState
        controller = appState.practiceController
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Practice · 模拟面试").font(.largeTitle.bold())
                Text("Answer first, then review. Local Qwen evaluates your submitted answer; subjective feedback is not a hiring prediction. No CV is required for general tasks.").foregroundStyle(.secondary)
                if !appState.settings.saveTranscriptsLocally || controller.run?.historyAllowed == false { Text("This practice is temporary and cannot be restored. To save future answers after enabling history, start a new practice.").foregroundStyle(.orange) }
                if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if controller.importingMaterial { ProgressView("Extracting question material locally…") }
                if let run = controller.run {
                    activeRun(run)
                } else {
                    configuration
                }
                Divider()
                reviewCards
            }.padding(24).frame(maxWidth: 1000, alignment: .leading)
        }
        .onAppear { controller.refreshReviews() }
        .onDisappear { controller.pause() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, .image, UTType(filenameExtension: "docx")!]) { result in
            guard case .success(let url) = result else { return }
            controller.importMaterial(from: url)
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context: \(appState.activeCandidateProfile?.displayName ?? "General practice") · \(appState.activeOpportunityContext?.title ?? "No selected role")")
            Picker("Task", selection: $kind) { ForEach(InterviewTaskKind.allCases) { Text($0.title).tag($0) } }
                .onChange(of: kind) { _, next in question = next.starter(chinese: language == "zh"); rubric = next.criteria.joined(separator: "\n") }
            Picker("Answer language", selection: $language) { Text("English").tag("en"); Text("中文").tag("zh") }
                .onChange(of: language) { _, value in question = kind.starter(chinese: value == "zh") }
            Picker("Feedback language", selection: $explanationLanguage) { Text("English").tag("en"); Text("中文").tag("zh") }
            Text("Speech recognition uses the selected ASR provider's supported languages. Chinese text does not imply Chinese audio support.").font(.caption)
            Text("Question (editable)").font(.headline)
            TextEditor(text: $question).frame(height: 90).border(.secondary.opacity(0.3))
            DisclosureGroup("Evaluation criteria (editable, one per line)") { TextEditor(text: $rubric).frame(height: 120) }
            Stepper("Maximum follow-ups: \(followUps)", value: $followUps, in: 0...2)
            Button("Start Practice / 开始练习") { controller.start(kind: kind, question: question, language: language, criteria: rubric.components(separatedBy: .newlines).filter { !$0.isEmpty }, maxFollowUps: followUps, explanationLanguage: explanationLanguage) }
                .buttonStyle(.borderedProminent).disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.primaryHomeActionShouldStop)
        }
    }
    @ViewBuilder private func activeRun(_ run: PracticeRun) -> some View {
        Text("\(run.phase.rawValue) · question \(run.questionID.prefix(8)) · follow-up \(run.followUpCount)/\(run.maxFollowUps)").font(.caption).foregroundStyle(.secondary)
        Text(run.task.question).font(.title2).textSelection(.enabled)
        if let attachment = run.attachment {
            if let bytes = run.attachmentOriginalData, let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260)
            }
            DisclosureGroup("Material: \(attachment.filename) · revision \(run.attachmentRevision)") {
                Text(attachment.warnings.joined(separator: " ")).foregroundStyle(.orange)
                Text(attachment.text).font(.body.monospaced()).textSelection(.enabled)
            }
        }
        HStack {
            Button("Add Question Material / 图片题") { importing = true }
                .disabled([.paused, .cancelled].contains(run.phase))
            Button("Pause") { controller.pause() }
            Button("Cancel") { controller.cancel() }
            Button("New Question") { controller.cancel(); controller.run = nil }
        }
        if run.phase == .asking || run.phase == .followUp {
            Button("Read Question Aloud") { controller.speakQuestion() }
            Button("Answer / 开始作答") { controller.beginAnswer() }.buttonStyle(.borderedProminent)
            Text("Listening starts only when you press Record after entering the answer step. Reading aloud stops before answering.").font(.caption)
        }
        if run.phase == .paused { Button("Resume / 继续") { controller.resume() } }
        if run.phase == .answering {
            TextEditor(text: Binding(get: { controller.run?.draft ?? "" }, set: { controller.run?.draft = $0 }))
                .font(.body.monospaced()).frame(minHeight: 200).border(.secondary.opacity(0.3))
            Text("Review and correct microphone text before submitting. Submitting confirms this is your answer; audio channel alone does not identify you.").font(.caption)
            HStack {
                Button(controller.microphoneStarting ? "Starting…" : controller.recording ? "Stop Recording" : "Record Answer") { if controller.recording || controller.microphoneStarting { controller.stopMicrophone() } else { controller.startMicrophone() } }
                Button("Hint") { controller.hint() }
                Button("Skip") { controller.submit(skipped: true) }
                Button("Submit Answer / 提交回答") { controller.submit() }.buttonStyle(.borderedProminent)
            }
            if run.hinted { Text(run.task.criteria.joined(separator: " → ")).foregroundStyle(.secondary) }
        }
        if run.phase == .evaluating { ProgressView("Evaluating with local Qwen…") }
        if run.phase == .failed { Button("Retry Evaluation") { controller.retryEvaluation() }; Button("Edit Answer") { controller.redo() } }
        if run.phase == .completed || run.phase == .followUp, let attempt = run.attempts.last {
            if let feedback = attempt.feedback {
                Text("Feedback · \(attempt.hinted ? "assisted attempt" : "unprompted attempt")").font(.headline)
                ForEach(Array(feedback.covered.enumerated()), id: \.offset) { _, item in
                    Text("\(item.criterion): “\(item.quote)” [answer \(attempt.id.prefix(8))]").textSelection(.enabled)
                }
                Text("Missing: " + feedback.missing.joined(separator: "; "))
                Text(feedback.suggestions.joined(separator: "\n"))
                Text("Next question reason: " + feedback.reason).foregroundStyle(.secondary)
                DisclosureGroup("Reference approach — system generated") { Text(feedback.reference).textSelection(.enabled) }
                Text("Code / calculation: not executed by this evaluation. Use the explicit SQL tool for an actual check.").font(.caption)
                HStack {
                    if run.phase == .completed, feedback.followUp != nil, run.followUpCount < run.maxFollowUps { Button("Targeted Follow-up / 针对性追问") { controller.followUp() } }
                    Button("Answer Again (assisted)") { controller.redo() }
                    if [.coding, .data, .research].contains(run.task.kind) { Button("Save Knowledge Review Card") { controller.addKnowledgeCard() }.disabled(!appState.settings.saveTranscriptsLocally) }
                    Button("Open Session / Recap") { appState.loadSessionDetails(sessionID: run.sessionID); appState.selectSection(.sessions) }
                }
            } else if attempt.skipped { Text("Skipped; no ability judgement recorded.") }
        }
    }
    private var reviewCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Knowledge Review · 知识复练").font(.title2)
            Text("FSRS schedules recall only. Rate your own recall after trying; subjective design quality and job fit are not memory probabilities.").font(.caption)
            ForEach(controller.reviews) { card in
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.question).font(.headline)
                    Text("Due: \(card.card.due.formatted()) · \(card.hinted ? "created from assisted attempt" : "created from unprompted attempt")").font(.caption)
                    Button("Reveal After Recall") { revealedReviews.insert(card.id) }
                    if revealedReviews.contains(card.id) {
                        Text(card.answer).textSelection(.enabled)
                        HStack {
                            ForEach([1, 2, 3, 4], id: \.self) { rating in
                                Button(["Again", "Hard", "Good", "Easy"][rating - 1]) { controller.rate(card, rating: Rating(rawValue: rating)!); revealedReviews.remove(card.id) }
                            }
                        }
                    }
                    Button("Delete Card", role: .destructive) { controller.deleteReview(card.id) }
                }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
