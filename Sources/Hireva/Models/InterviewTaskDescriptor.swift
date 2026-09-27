import Foundation

enum InterviewTaskKind: String, CaseIterable, Codable, Identifiable {
    case motivation, behavioral, project, coding, systemDesign, data, research, arrangements, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .motivation: return "HR / Motivation · 动机"
        case .behavioral: return "Behavioral · 行为"
        case .project: return "Project · 项目深挖"
        case .coding: return "Coding / Debugging · 编程"
        case .systemDesign: return "System Design · 系统设计"
        case .data: return "Data / SQL · 数据"
        case .research: return "Research · 研究答辩"
        case .arrangements: return "Offer / Arrangements · 工作安排"
        case .unknown: return "Clarify · 需澄清"
        }
    }
    var criteria: [String] {
        switch self {
        case .motivation: return ["Role requirements / 岗位需求", "Supported experience / 真实经历", "Motivation / 动机", "Questions to ask / 反问"]
        case .behavioral: return ["Situation / 情境", "Personal action / 个人行动", "Result / 结果", "Reflection / 反思"]
        case .project: return ["Contribution / 个人贡献", "Baseline / 基线", "Experiment / 实验", "Failure and trade-offs / 失败与取舍"]
        case .coding: return ["Input and constraints / 输入与约束", "Algorithm / 算法", "Complexity / 复杂度", "Tests and boundaries / 测试与边界"]
        case .systemDesign: return ["Requirements / 需求", "Components and data flow / 组件与数据流", "Bottlenecks / 瓶颈", "Reliability and trade-offs / 可靠性与取舍"]
        case .data: return ["Schema and definitions / 表结构与口径", "NULL and duplicates / 空值与重复", "Calculation and units / 计算与单位", "Limitations / 推断限制"]
        case .research: return ["Research question / 研究问题", "Contribution boundary / 贡献边界", "Experimental design / 实验设计", "Limitations and next test / 局限与可检验下一步"]
        case .arrangements: return ["Confirmed preferences / 已确认偏好", "Constraints / 约束", "Unverified policies / 待核实政策", "Clarifying questions / 澄清问题"]
        case .unknown: return ["Clarify the task and missing constraints / 澄清任务与缺失条件"]
        }
    }
    func starter(chinese: Bool) -> String {
        switch self {
        case .motivation: return chinese ? "这个岗位的哪些工作吸引你？请区分已具备的经历和希望学习的内容。" : "What attracts you to this role, and which experience supports that interest?"
        case .behavioral: return chinese ? "讲一次你与团队意见不一致的真实事件，你做了什么，有什么反思？" : "Describe a real disagreement with a team, your actions, and what you learned."
        case .project: return chinese ? "选一个项目，说明个人贡献、基线、实验和一次失败。" : "Choose a project and explain your contribution, baseline, experiments, and one failure."
        case .coding: return chinese ? "如何查找无序整数数组中的两个数，使其和等于目标值？说明边界、复杂度和测试。" : "Find two numbers in an unsorted integer array whose sum equals a target. Explain constraints, complexity, and tests."
        case .systemDesign: return chinese ? "设计一个通知服务。先澄清需求，再说明组件、数据流和可靠性取舍。" : "Design a notification service. Clarify requirements, then explain components, data flow, and reliability trade-offs."
        case .data: return chinese ? "按客户统计订单总额。如何处理没有订单的客户、NULL 和重复记录？" : "Calculate total order value per customer. How do you handle customers with no orders, NULL, and duplicates?"
        case .research: return chinese ? "提出一个可检验的研究问题，设计实验并讨论贡献边界和局限。" : "Propose a falsifiable research question, design an experiment, and explain contribution boundaries and limitations."
        case .arrangements: return chinese ? "如何说明你已确认的工作安排偏好，以及仍需向招聘方确认的条件？" : "How would you communicate confirmed working preferences and clarify conditions with the employer?"
        case .unknown: return chinese ? "你希望讨论哪个问题？还缺少哪些条件？" : "Which problem should we discuss, and what constraints are missing?"
        }
    }
}

/// Frozen, small task description shared by live prompts and practice. Routing is
/// a heuristic, never a calibrated probability or an authority on personal facts.
struct InterviewTaskDescriptor: Codable, Hashable {
    var kind: InterviewTaskKind
    var question: String
    var language: String
    var explanationLanguage: String?
    var requiresPersonalEvidence: Bool
    var criteria: [String]
    var rubricVersion = "interview-rubric-v1"
    var allowedTools: [String] = []

    init(question: String, kind: InterviewTaskKind? = nil, language: String? = nil) {
        self.question = question
        self.kind = kind ?? Self.classify(question)
        self.language = language ?? (question.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } ? "zh" : "en")
        requiresPersonalEvidence = (kind != nil && [.motivation, .behavioral, .project, .arrangements].contains(self.kind)) || Self.requiresPersonalEvidence(question)
        criteria = self.kind.criteria
    }

    static func requiresPersonalEvidence(_ question: String) -> Bool {
        let text = question.lowercased()
        // Possessives also describe hypothetical solutions ("your algorithm").
        // Require biographical/completed-action language, not the pronoun alone.
        let personalPossessive = text.range(of: #"\b(your (experience|background|career|salary|availability|notice period|visa|qualification|achievement)|you (have worked|have built|had|did|were|worked|built|led|delivered|achieved))\b"#, options: .regularExpression) != nil
        let chinesePersonal = ["你的经历", "你的背景", "你的薪资", "你的签证", "你曾", "你之前", "你本人", "你做过", "你收到", "你提出"].contains(where: text.contains)
        let ownedResearch = text.range(
            of: #"\byour (?:[a-z-]+\s+){0,6}(research|thesis|dissertation|paper|study|method|experiments|work)\b"#,
            options: .regularExpression
        ) != nil
        if personalPossessive || chinesePersonal || ownedResearch { return true }
        return ["your experience", "your project", "your background", "you built", "you worked", "tell me about yourself", "introduce yourself", "a time when you", "your contribution", "你曾", "你的项目", "你的经历", "个人贡献", "真实事件", "自我介绍"].contains(where: text.contains)
    }

    static func classify(_ question: String) -> InterviewTaskKind {
        let text = question.lowercased()
        func has(_ terms: [String]) -> Bool { terms.contains(where: text.contains) }
        if has(["sql", "dataset", "query", "null", "数据分析", "查询", "表结构", "订单"]) { return .data }
        if has(["debug", "algorithm", "code", "coding", "array", "编程", "调试", "算法", "数组"]) { return .coding }
        if has(["system design", "design a", "architecture", "data flow", "设计一个", "系统设计", "架构"]) { return .systemDesign }
        if has(["research", "hypothesis", "thesis", "paper", "实验设计", "论文", "研究"]) { return .research }
        if has(["offer", "salary", "visa", "working hours", "relocation", "薪资", "签证", "工作安排"]) { return .arrangements }
        if has(["conflict", "disagreement", "a time", "mistake", "behavioral", "真实事件", "冲突", "分歧"]) { return .behavioral }
        if has(["project", "contribution", "baseline", "ablation", "项目", "贡献", "消融"]) { return .project }
        if has(["role", "motivat", "yourself", "join", "岗位", "动机", "自我介绍"]) { return .motivation }
        return .unknown
    }
    var promptPolicy: String {
        "Task: \(kind.rawValue); answer language: \(language). Rubric: \(criteria.joined(separator: "; ")). Personal evidence required: \(requiresPersonalEvidence). Never convert requirements, notes, plans, or generated drafts into past personal accomplishments. Ask only for genuinely missing constraints. An unknown task category does not mean the spoken question is incomplete; answer general knowledge without inventing personal facts. Tools require explicit application authorization."
    }
}
