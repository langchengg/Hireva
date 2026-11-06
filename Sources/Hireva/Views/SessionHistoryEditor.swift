import SwiftUI

struct SessionHistoryEditor: View {
    // App policy and Practice controls remain coordinated by AppState; saved
    // transcript records are observed through their single History owner.
    @ObservedObject var appState: AppState
    @ObservedObject private var historyState: HistoryState
    let session: InterviewSession

    init(appState: AppState, session: InterviewSession) {
        self.appState = appState
        self.session = session
        historyState = appState.historyState
    }
    var body: some View {
        let history = (try? HistoryCorrectionRepository(database: appState.database).revisions(sessionID: session.id)) ?? []
        let revision = (try? appState.sessionRepository.session(id: session.id))?.contentRevision ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct saved inputs · 历史纠错").font(.headline)
            Text("Input revision \(revision). Corrections do not confirm personal facts. Save, then explicitly re-evaluate. Earlier answers and feedback remain labeled with their original inputs.").font(.caption)
            if let practice = try? PracticeRepository(database: appState.database).load(sessionID: session.id) {
                ForEach(practice.attempts) { attempt in
                    PracticeHistoryRow(appState: appState, sessionID: session.id, attempt: attempt).id(attempt.id + "-\(attempt.revision)-\(attempt.feedback != nil)")
                }
            }
            ForEach(historyState.selectedSessionTranscript) { segment in
                TranscriptHistoryRow(appState: appState, segment: segment, correction: history.last { $0.segmentID == segment.id }, isDetectedQuestion: ((try? appState.suggestionRepository.questions(sessionID: session.id)) ?? []).contains { $0.transcriptSegmentID == segment.id })
                    .id(segment.id + "-\(history.last { $0.segmentID == segment.id }?.revision ?? 0)")
            }
            ForEach((try? appState.recapRepository.versions(sessionID: session.id)) ?? []) { recap in
                DisclosureGroup("Recap input v\(recap.contentRevision ?? 0)\((recap.contentRevision ?? 0) < revision ? " · based on old inputs / 旧版本" : " · current")") {
                    Text(recap.markdown).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TranscriptHistoryRow: View {
    @ObservedObject var appState: AppState
    let segment: TranscriptSegment
    let correction: HistoryCorrection?
    @State var text: String
    @State var speaker: SpeakerRole
    @State var startsQuestion: Bool
    @State var question: String
    init(appState: AppState, segment: TranscriptSegment, correction: HistoryCorrection?, isDetectedQuestion: Bool) {
        self.appState = appState; self.segment = segment; self.correction = correction
        _text = State(initialValue: correction?.text ?? segment.text)
        _speaker = State(initialValue: correction?.speaker ?? segment.speaker)
        _startsQuestion = State(initialValue: correction?.startsQuestion ?? isDetectedQuestion)
        _question = State(initialValue: correction?.questionText ?? (isDetectedQuestion ? segment.text : ""))
    }
    var body: some View {
        DisclosureGroup("Source \(segment.id.prefix(8)) · input v\(correction?.revision ?? 0)") {
            Text("Original ASR (\(segment.speaker.displayName)): \(segment.text)").textSelection(.enabled)
            TextEditor(text: $text).frame(minHeight: 90).border(.secondary.opacity(0.3))
            Picker("Corrected speaker", selection: $speaker) {
                Text("Unknown").tag(SpeakerRole.unknown)
                Text("Interviewer").tag(SpeakerRole.interviewer)
                Text("Candidate").tag(SpeakerRole.candidate)
            }
            Toggle("Starts a question unit", isOn: $startsQuestion)
            if startsQuestion { TextField("Question boundary / corrected question", text: $question) }
            Button("Save New Input Version / 保存纠正版本") {
                appState.saveTranscriptCorrection(segment, text: text, speaker: speaker, startsQuestion: startsQuestion, question: startsQuestion ? question : "")
            }
        }
    }
}

private struct PracticeHistoryRow: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var controller: PracticeController
    let sessionID: String
    let attempt: PracticeAttempt
    @State var question: String
    @State var answer: String
    init(appState: AppState, sessionID: String, attempt: PracticeAttempt) {
        self.appState = appState; self.sessionID = sessionID; self.attempt = attempt
        controller = appState.practiceController
        _question = State(initialValue: attempt.question); _answer = State(initialValue: attempt.answer)
    }
    var body: some View {
        DisclosureGroup("Attempt \(attempt.id.prefix(8)) · v\(attempt.revision) · \(attempt.hinted ? "assisted" : "unprompted")") {
            TextField("Correct question", text: $question)
            TextEditor(text: $answer).frame(minHeight: 110).border(.secondary.opacity(0.3))
            HStack {
                Button("Save Corrected Attempt / 保存纠错") { appState.correctPracticeAttempt(sessionID: sessionID, attemptID: attempt.id, question: question, answer: answer) }
                Button("Re-evaluate This Attempt / 重评本题") {
                    controller.restore(sessionID: sessionID)
                    controller.reevaluate(attemptID: attempt.id)
                }.disabled(appState.primaryHomeActionShouldStop || attempt.feedback != nil || attempt.skipped || controller.run?.phase == .evaluating)
            }
            if let feedback = attempt.feedback {
                Text("Current feedback · v\(attempt.revision)")
                ForEach(Array(feedback.assessmentLines.enumerated()), id: \.offset) { _, line in Text("\(line) [\(attempt.id) v\(attempt.revision)]").textSelection(.enabled) }
                Text(feedback.suggestions.joined(separator: "\n"))
                if ((try? PracticeRepository(database: appState.database).reviews()) ?? []).contains(where: { $0.id == attempt.id && $0.needsReevaluation == true }) {
                    Button("Update Review Card (keep rating history)") { controller.updateCorrectedReview(sessionID: sessionID, attemptID: attempt.id) }
                }
            } else { Text("Not re-evaluated. Older feedback is not a score for the corrected input.").foregroundStyle(.orange) }
            ForEach(Array((attempt.corrections ?? []).enumerated()), id: \.offset) { _, old in
                DisclosureGroup("Original input / old feedback v\(old.revision)") {
                    Text(old.hinted.map { $0 ? "Assisted original attempt" : "Unprompted original attempt" } ?? "Original assistance status was not recorded")
                    Text(old.question + "\n" + old.answer).textSelection(.enabled)
                    if let feedback = old.feedback {
                        ForEach(Array(feedback.assessmentLines.enumerated()), id: \.offset) { _, line in Text("\(line) [\(attempt.id) v\(old.revision)]").textSelection(.enabled) }
                        Text(feedback.suggestions.joined(separator: "\n"))
                    } else { Text("Not evaluated") }
                }
            }
        }
    }
}
