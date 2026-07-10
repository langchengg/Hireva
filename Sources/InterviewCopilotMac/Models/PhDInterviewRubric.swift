import Foundation

enum PhDQuestionIntent: String, Codable, CaseIterable {
    case preMScBackground = "pre_msc_background"
    case llmVlmExperience = "llm_vlm_experience"
    case publicationPlan = "publication_plan"
    case skillFit = "skill_fit"
    case tactileRole = "tactile_role"
    case tactileSlipResponse = "tactile_slip_response"
    case tactileExperience = "tactile_experience"
    case tactileLearningPlan = "tactile_learning_plan"
    case realRobotExperience = "real_robot_experience"
    case robotArchitecture = "robot_architecture"
    case rosControl = "ros_control"
    case graspResearch = "grasp_research"
}

struct PhDInterviewRubric: Equatable {
    let intent: PhDQuestionIntent
    let expectedAnswerTopics: [[String]]
    let minimumTopicMatches: Int
    let mustAvoid: [String]
    let honestyConstraints: [String]
}

struct PhDAnswerQualityResult: Equatable {
    let intent: PhDQuestionIntent?
    let passed: Bool
    let matchedTopicGroups: Int
    let missingTopicGroups: [String]
    let violations: [String]
    let firstPerson: Bool
    let genericTemplate: Bool
}

/// De-identified evaluation rubric for the representative PhD dialogue turns.
/// It contains topic constraints, not complete candidate answers.
enum PhDInterviewRubricPolicy {
    static func intent(for question: String) -> PhDQuestionIntent? {
        let lower = normalize(question)
        if lower.contains("tactile"),
           lower.contains("slip") || lower.contains("slipping") || lower.contains("unstable grasp") {
            return .tactileSlipResponse
        }
        if lower.contains("tactile"),
           lower.contains("not yet worked") ||
            lower.contains("worked directly") ||
            lower.contains("skills gap") ||
            lower.contains("close that gap") ||
            lower.contains("first six months") {
            return .tactileLearningPlan
        }
        if lower.contains("tactile"),
           lower.contains("experience") ||
            lower.contains("from your reading") ||
            lower.contains("hands on") {
            return .tactileExperience
        }
        if lower.contains("tactile"),
           lower.contains("role") || lower.contains("play in") || lower.contains("slip") || lower.contains("contact") {
            return .tactileRole
        }
        if lower.contains("llm") || lower.contains("vlm") {
            return .llmVlmExperience
        }
        if lower.contains("publish") || lower.contains("publication") {
            return .publicationPlan
        }
        if lower.contains("current grasping research"),
           lower.contains("contribution") || lower.contains("contribute") || lower.contains("strongest evidence") {
            return .graspResearch
        }
        if lower.contains("skill set") || lower.contains("experience fit this project") {
            return .skillFit
        }
        if (lower.contains("using ros") || lower.contains("use ros")) && lower.contains("python") {
            return .rosControl
        }
        if lower.contains("which robot") ||
            lower.contains("what architecture") ||
            lower.contains("which platform") ||
            lower.contains("control architecture") ||
            (lower.contains("robot arm") && lower.contains("architecture")) {
            return .robotArchitecture
        }
        if lower.contains("controlled a real robot") || lower.contains("control the real robot") {
            return .realRobotExperience
        }
        if lower.contains("prior to your msc") ||
            lower.contains("before manchester") ||
            lower.contains("before your msc") ||
            lower.contains("before the msc") ||
            lower.contains("before msc") ||
            lower.contains("before the master") ||
            (lower.contains("before starting") && (lower.contains("msc") || lower.contains("master"))) ||
            lower.contains("what was your background") {
            return .preMScBackground
        }
        if (lower.contains("grasp") && (
            lower.contains("re ranking") ||
            lower.contains("reranking") ||
            lower.contains("semantic and geometric")
        )) || (lower.contains("failure cases") && lower.contains("real robot")) {
            return .graspResearch
        }
        return nil
    }

    static func rubric(for question: String) -> PhDInterviewRubric? {
        guard let intent = intent(for: question) else { return nil }
        switch intent {
        case .preMScBackground:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["computer science"], ["deep learning", "nlp"], ["before my msc", "prior to my msc", "before manchester"]],
                minimumTopicMatches: 2,
                mustAvoid: [
                    "extensive robotics experience before",
                    "years of robotics before",
                    "robotics before my msc",
                    "vla before my msc",
                    "vision language action models before my msc",
                    "real robot before my msc"
                ],
                honestyConstraints: ["Distinguish pre-MSc background from later robotics work."]
            )
        case .llmVlmExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["newer", "new to"], ["nlp", "deep learning"], ["msc", "current"]],
                minimumTopicMatches: 3,
                mustAvoid: ["years of vlm", "extensive vlm experience"],
                honestyConstraints: ["State that LLM/VLM robotics experience is recent."]
            )
        case .publicationPlan:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["possible", "could", "if"], ["dissertation", "benchmark"], ["results", "supervisor", "align"]],
                minimumTopicMatches: 2,
                mustAvoid: ["will definitely publish", "publication is guaranteed", "already published"],
                honestyConstraints: ["Describe publication as conditional, not guaranteed."]
            )
        case .skillFit:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["perception", "visual grounding"], ["manipulation", "grasp"], ["ros2", "real robot"], ["tactile", "world action", "world-action", "growth area"]],
                minimumTopicMatches: 3,
                mustAvoid: ["i am hardworking", "i would answer this directly"],
                honestyConstraints: ["Treat tactile/world-action modelling as a growth area."]
            )
        case .tactileRole:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["contact"], ["force"], ["slip"], ["pressure"], ["adapt", "closed loop", "closed-loop"], ["vision alone"]],
                minimumTopicMatches: 4,
                mustAvoid: [],
                honestyConstraints: ["Explain sensing after contact and closed-loop adaptation."]
            )
        case .tactileSlipResponse:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [
                    ["confirm", "verify", "detect"],
                    ["cautious", "gradual", "adjust grip force", "increase grip"],
                    ["reposition", "regrasp", "contact pose"],
                    ["replan", "retry"],
                    ["safe stop", "stop safely", "unrecoverable", "cannot recover"],
                    ["closed loop", "closed-loop", "tactile feedback"]
                ],
                minimumTopicMatches: 5,
                mustAvoid: ["immediately abort the current motion and apply a corrective force"],
                honestyConstraints: ["Use cautious closed-loop recovery and include a safe stop when the grasp cannot be stabilized."]
            )
        case .tactileExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [
                    ["reading", "study", "literature"],
                    ["not hands on", "not hands-on", "rather than hands on", "acknowledge that gap", "limited hands on"],
                    ["learn", "develop"],
                    ["perception", "manipulation", "ros2"]
                ],
                minimumTopicMatches: 3,
                mustAvoid: ["extensive hands-on", "years of tactile hardware"],
                honestyConstraints: ["Do not claim hands-on tactile hardware experience."]
            )
        case .tactileLearningPlan:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [
                    ["reading", "study", "literature"],
                    ["not hands on", "not hands-on", "rather than hands on", "acknowledge that gap", "limited hands on"],
                    ["learn", "develop"],
                    ["perception", "manipulation", "ros2"],
                    ["tactile calibration", "calibrate tactile", "sensor calibration", "controlled contact", "contact experiment"],
                    ["data acquisition", "signal processing", "slip experiment"],
                    ["supervisor", "lab guidance", "guidance from the lab"]
                ],
                minimumTopicMatches: 5,
                mustAvoid: [
                    "extensive hands-on",
                    "years of tactile hardware",
                    "leorover",
                    "camera and imu",
                    "imu inputs",
                    "dexory",
                    "warehouse logistics"
                ],
                honestyConstraints: ["Do not claim hands-on tactile hardware experience."]
            )
        case .realRobotExperience:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["real robot", "robot arm"], ["controlled", "control"], ["current dissertation", "distinct", "physical testing"]],
                minimumTopicMatches: 2,
                mustAvoid: [],
                honestyConstraints: ["Keep prior robot work distinct from the current dissertation."]
            )
        case .robotArchitecture:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["robot arm", "arm control", "arm-control", "manipulator"], ["ros2"], ["perception", "manipulation", "architecture"]],
                minimumTopicMatches: 3,
                mustAvoid: ["raspberry"],
                honestyConstraints: ["Do not turn an uncertain ASR platform name into a factual claim."]
            )
        case .rosControl:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [["ros2"], ["python api", "python apis", "python library"], ["framework", "pipeline", "rather than replacing"]],
                minimumTopicMatches: 3,
                mustAvoid: [],
                honestyConstraints: ["Distinguish ROS2 orchestration from lower-level Python APIs."]
            )
        case .graspResearch:
            return PhDInterviewRubric(
                intent: intent,
                expectedAnswerTopics: [
                    ["semantic", "grounding", "referred target"],
                    ["geometric", "collision", "clearance"],
                    ["grasp", "re rank", "rerank"],
                    ["real robot", "evaluation", "failure case"]
                ],
                minimumTopicMatches: 3,
                mustAvoid: ["dexory", "leorover", "warehouse logistics"],
                honestyConstraints: ["Answer about the current semantic/geometric grasp re-ranking work, not an unrelated prior project or employer."]
            )
        }
    }

    static func evaluate(question: String, answer: String) -> PhDAnswerQualityResult {
        guard let rubric = rubric(for: question) else {
            let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer)
            return PhDAnswerQualityResult(
                intent: nil,
                passed: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !generic,
                matchedTopicGroups: 0,
                missingTopicGroups: [],
                violations: [],
                firstPerson: containsFirstPerson(answer),
                genericTemplate: generic
            )
        }

        let lowerAnswer = normalize(answer)
        let matches = rubric.expectedAnswerTopics.map { alternatives in
            alternatives.contains { lowerAnswer.contains(normalize($0)) }
        }
        let missing = zip(rubric.expectedAnswerTopics, matches).compactMap { topics, matched in
            matched ? nil : topics.joined(separator: "/")
        }
        var violations = rubric.mustAvoid.filter { containsUnnegatedClaim(normalize($0), in: lowerAnswer) }
        if rubric.intent == .preMScBackground {
            let roboticsIndicators = [
                "vision language action", "vla", "vlm", "robotic manipulation",
                "real robot", "physical robot", "grasp pose", "grasp re ranking", "grasp reranking"
            ]
            let laterTimelineIndicators = [
                "later", "during my msc", "during the msc", "at manchester",
                "after starting", "since starting", "developed through the msc"
            ]
            let mentionsRobotics = roboticsIndicators.contains { lowerAnswer.contains($0) }
            let marksRoboticsAsLater = laterTimelineIndicators.contains { lowerAnswer.contains($0) }
            if mentionsRobotics && !marksRoboticsAsLater {
                violations.append("robotics or VLA work is not explicitly placed after the pre-MSc period")
            }
        }
        if rubric.intent == .tactileLearningPlan,
           !["calibration", "calibrate"].contains(where: { lowerAnswer.contains($0) }) {
            violations.append("tactile learning plan omits sensor calibration")
        }
        if containsUnsupportedNumericMetric(answer) {
            violations.append("answer contains an unverified numeric performance metric")
        }
        if rubric.intent == .graspResearch,
           containsUnsupportedCompletedRealRobotClaim(lowerAnswer) {
            violations.append("answer presents planned real-robot validation as a completed result")
        }
        let firstPerson = containsFirstPerson(answer)
        let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer)
        let matchCount = matches.filter { $0 }.count
        return PhDAnswerQualityResult(
            intent: rubric.intent,
            passed: matchCount >= rubric.minimumTopicMatches && violations.isEmpty && firstPerson && !generic,
            matchedTopicGroups: matchCount,
            missingTopicGroups: missing,
            violations: violations,
            firstPerson: firstPerson,
            genericTemplate: generic
        )
    }

    static func promptGuidance(for question: String) -> String {
        guard let rubric = rubric(for: question) else { return "" }
        let topics = rubric.expectedAnswerTopics.map { $0.joined(separator: " or ") }.joined(separator: "; ")
        let facts = verifiedGroundingFacts(for: rubric.intent)
            .map { "- \($0)" }
            .joined(separator: "\n")
        return """
        PhD answer evidence rubric:
        Verified candidate facts:
        \(facts)
        - Cover the relevant evidence areas: \(topics).
        - \(rubric.honestyConstraints.joined(separator: " "))
        - Do not invent dates, metrics, employers, hardware models, publications, or experience beyond these verified facts.
        """
    }

    private static func verifiedGroundingFacts(for intent: PhDQuestionIntent) -> [String] {
        switch intent {
        case .preMScBackground:
            return [
                "Before the MSc, the background was computer science, deep learning, and NLP.",
                "Direct robotics, VLA, and physical-robot work developed later during the MSc."
            ]
        case .llmVlmExperience:
            return [
                "LLM and VLM robotics work is new during the current MSc year.",
                "Earlier deep-learning and NLP experience provided the transferable foundation."
            ]
        case .publicationPlan:
            return [
                "The current work is still at dissertation and benchmark stage.",
                "Publication is possible only if results are strong and align with the supervisor's research."
            ]
        case .skillFit:
            return [
                "Relevant strengths are robot perception, language-guided manipulation, grasp selection, and ROS2 integration.",
                "Tactile sensing and world-action modelling are growth areas rather than established hands-on expertise."
            ]
        case .tactileRole:
            return [
                "Vision provides target and scene information before contact.",
                "Tactile feedback provides contact location, force, slip, pressure, and stability for closed-loop adaptation."
            ]
        case .tactileSlipResponse:
            return [
                "Confirm the slip signal, then cautiously adjust grip force or contact pose rather than applying uncontrolled force.",
                "If the grasp remains unstable, reposition or regrasp, replan through the closed loop, and stop safely when recovery is not possible."
            ]
        case .tactileExperience:
            return [
                "Tactile knowledge currently comes from reading, not hands-on hardware work.",
                "Relevant perception, manipulation, and ROS2 experience can transfer while tactile hardware skills are developed experimentally."
            ]
        case .tactileLearningPlan:
            return [
                "Tactile knowledge currently comes from reading, not hands-on hardware work.",
                "A credible first-six-month plan starts with tactile sensor calibration, controlled contact and slip experiments, data acquisition, and signal processing.",
                "Integrate those observations into a small ROS2 manipulation loop with supervisor or lab guidance before larger tasks.",
                "Do not substitute an old mobile-robot platform, camera calibration, or IMU calibration for tactile hardware work."
            ]
        case .realRobotExperience:
            return [
                "Physical-robot control experience came from practical MSc robotics projects.",
                "Keep that prior project distinct from the current language-guided grasping dissertation."
            ]
        case .robotArchitecture:
            return [
                "The relevant platform was a robot arm controlled through ROS2.",
                "Perception produced a target or grasp pose, ROS2 passed it to planning and arm-control components, and execution feedback confirmed or recovered the motion.",
                "Do not claim an uncertain platform or hardware model as fact."
            ]
        case .rosControl:
            return [
                "ROS2 orchestrated the robot pipeline and did not replace the lower-level Python APIs.",
                "This control work belonged to a prior practical project, distinct from the current dissertation."
            ]
        case .graspResearch:
            return [
                "The current contribution is semantic and geometric re-ranking of grasp candidates for a referred target.",
                "Evidence includes detector confidence, target overlap, semantic consistency, gripper clearance, and collision risk.",
                "This current re-ranking method has not yet been validated on a real robot; describe real-robot evaluation in future tense.",
                "Future real-robot validation should prioritize grounding errors, calibration and geometry errors, collision or clearance failures, and execution recovery."
            ]
        }
    }

    private static func containsFirstPerson(_ text: String) -> Bool {
        let normalized = " \(normalize(text)) "
        return normalized.contains(" i ") || normalized.contains(" my ")
    }

    private static func containsUnnegatedClaim(_ claim: String, in answer: String) -> Bool {
        let answerWords = answer.split(separator: " ").map(String.init)
        let claimWords = claim.split(separator: " ").map(String.init)
        guard !claimWords.isEmpty, answerWords.count >= claimWords.count else { return false }
        for start in 0...(answerWords.count - claimWords.count) {
            guard Array(answerWords[start..<(start + claimWords.count)]) == claimWords else { continue }
            let contextStart = max(0, start - 4)
            let prefix = answerWords[contextStart..<start]
            if !prefix.contains(where: { ["not", "no", "never", "without"].contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func containsUnsupportedNumericMetric(_ text: String) -> Bool {
        let pattern = #"(?:\b\d+(?:\.\d+)?\s*(?:%|ms\b|milliseconds?\b|fps\b|hz\b)|\b\d+(?:\.\d+)?\s+percent(?:age)?\b)"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsUnsupportedCompletedRealRobotClaim(_ normalizedAnswer: String) -> Bool {
        guard normalizedAnswer.contains("real robot") else { return false }
        let completedResultIndicators = [
            "i demonstrated", "we demonstrated", "i achieved", "we achieved",
            "i validated", "we validated", "i have validated", "we have validated",
            "during real robot validation", "demonstrated improved",
            "integrated it into a real robot pipeline",
            "integrated these constraints into a real robot pipeline",
            "significantly improved reliability"
        ]
        return completedResultIndicators.contains { normalizedAnswer.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
