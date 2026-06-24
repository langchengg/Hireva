import Foundation

/// Local, project-grounded first answers used when provider streaming is late or
/// alignment rejects a provider answer.
enum ProjectGroundedFallbackPolicy {
    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        switch IntentRouter.answerIntent(for: question.questionText) {
        case .tellMeAboutYourself:
            return IntentFallbackAnswer(
                sayFirst: "I’m currently studying MSc Robotics at the University of Manchester, and my computer science background brought me into robotics because it combines software, perception, manipulation, and real-world AI systems.",
                keyPoints: ["MSc Robotics and computer science background.", "Interest in robotics through software, perception, control, and AI.", "Recent direction: perception, manipulation, and decision making."]
            )
        case .projectWalkthrough:
            return IntentFallbackAnswer(
                sayFirst: "My LeoRover project was an autonomous object retrieval robot. I worked on the ROS2 pipeline, YOLOv8 object detection, target localisation, navigation coordination, and connecting that perception output to manipulation.",
                keyPoints: ["Goal: search, localise, navigate, and pick up a target object.", "Role: ROS2, YOLOv8, localisation, navigation, and manipulation coordination.", "Learning: real robot integration matters as much as each module."]
            )
        case .technicalChallenge:
            return IntentFallbackAnswer(
                sayFirst: "The hardest technical challenge was making the real robot pipeline reliable, because noisy perception, localisation instability, timing mismatch, and module integration made real robot execution much less predictable than simulation.",
                keyPoints: ["Challenge: perception, localisation, navigation, and manipulation integration.", "Why hard: noisy inputs and real robot uncertainty.", "Outcome: added more robust coordination and recovery behaviour."]
            )
        case .errorHandling:
            return IntentFallbackAnswer(
                sayFirst: "I handled noisy detections by using filtering, repeated observations, and a stability threshold before acting, then adding recovery behaviour such as retrying, repositioning, or adjusting when localisation was unreliable.",
                keyPoints: ["Did not trust a single detection.", "Used repeated observations and stability checks.", "Added retry, reposition, and recovery behaviour."]
            )
        case .modelComparison, .diffusionPolicy:
            return IntentFallbackAnswer(
                sayFirst: "My interpretation is that a diffusion-based policy can be more stable because it denoises a whole continuous action sequence or trajectory, which tends to produce smoother and more robust manipulation motions. An autoregressive policy predicts actions step by step, so small mistakes can compound and accumulate over the sequence.",
                keyPoints: ["Diffusion refines a full continuous action trajectory through denoising.", "Autoregressive and flow-matching variants were less robust, and autoregressive prediction can accumulate compounding errors step by step.", "In MuJoCo, diffusion reached seven out of ten successful grasps, helped by smoother action generation."]
            )
        case .decoderComparison:
            return IntentFallbackAnswer(
                sayFirst: "In the MuJoCo VLA Franka simulation, I learned that the decoder architecture strongly affects action trajectory quality: the diffusion decoder was best at about 7/10 successful grasps, while autoregressive and flow-matching were weaker at about 1/10 because they were less stable for continuous manipulation.",
                keyPoints: ["Compared autoregressive, diffusion, and flow-matching decoders in the MuJoCo VLA project.", "Diffusion handled smooth continuous action trajectories more robustly.", "Lesson learned: decoder architecture matters because autoregressive prediction can accumulate errors and flow-matching was harder to stabilize in this setup."]
            )
        case .perceptionDebugging:
            return IntentFallbackAnswer(
                sayFirst: "I would debug a confident but wrong YOLOv8 prediction on the LeoRover by reproducing the exact frames, inspecting logs, bounding boxes, classes, and confidence, then checking calibration, lighting, occlusion, motion blur, and spatial or temporal consistency before deciding whether retraining is needed.",
                keyPoints: ["Inspect frames, logs, boxes, classes, and confidence scores.", "Check calibration, lighting, glare, occlusion, and motion blur.", "Add validation or recovery behavior before retraining or adding data."]
            )
        case .technicalTradeoff:
            return IntentFallbackAnswer(
                sayFirst: "The biggest trade-off was robustness versus latency and complexity. On LeoRover, I chose practical filtering, recovery behaviour, and ROS2 coordination over adding more complex model changes first, because reliable real-robot execution mattered more than a cleaner demo pipeline.",
                keyPoints: ["Trade-off: robustness and reliability versus latency, complexity, and integration speed.", "Concrete choice: filtering, recovery, and coordination before heavier model changes.", "Lesson: robotics systems need dependable execution, not just strong individual modules."]
            )
        case .datasetAdaptation:
            return IntentFallbackAnswer(
                sayFirst: "I adapted the DROID real-robot trajectories by treating them as demonstrations to reproduce in the MuJoCo Franka setup, mapping the robot actions and observations into the simulator format, checking timing and coordinate consistency, and validating that the simulated motions still matched the manipulation objective.",
                keyPoints: ["Mapped DROID demonstrations into the MuJoCo Franka action and observation format.", "Checked coordinate frames, timing, and trajectory consistency.", "Validated the simulation against the original manipulation behavior before training or evaluation."]
            )
        case .simToRealDebugging:
            return IntentFallbackAnswer(
                sayFirst: "I would diagnose the sim-to-real gap by comparing simulator and real-robot observations, action scaling, timing, calibration, contact dynamics, and failure videos, then isolate whether the issue comes from perception, control, dynamics mismatch, or distribution shift before changing the policy.",
                keyPoints: ["Compare sim and real observations, actions, timing, and calibration.", "Inspect contact dynamics, latency, and failure videos.", "Isolate perception, control, dynamics, or data distribution issues before retraining."]
            )
        case .projectComparison:
            return IntentFallbackAnswer(
                sayFirst: "The VLA project was a learning-and-simulation project: I adapted DROID trajectories into a MuJoCo Franka setup and compared autoregressive, diffusion, and flow-matching decoders for visuomotor control. LeoRover was a real-robot systems project where I integrated ROS2, YOLOv8 detection, localisation, navigation, manipulation, and recovery behaviour on physical hardware. So VLA evaluated learned policy architectures, while LeoRover tested reliable perception-to-action deployment.",
                keyPoints: ["VLA: DROID trajectories, MuJoCo/Franka, learned visuomotor policies, and decoder comparison.", "LeoRover: ROS2, YOLOv8, localisation, navigation, manipulation, and recovery on a real robot.", "Main difference: model-learning research in simulation versus real-world system integration and deployment."]
            )
        case .systemIntegrationDebugging:
            return IntentFallbackAnswer(
                sayFirst: "On LeoRover, YOLOv8 detections fed the ROS2 perception pipeline, which turned object detections into target poses for localisation, navigation, and manipulation. I treated it as a system integration problem: I compared logs and timestamps across modules, then added validation and recovery behaviour so the robot could retry when detection, localisation, or execution was uncertain.",
                keyPoints: ["YOLOv8 detection produced target information for localisation and navigation.", "Manipulation depended on validated perception and robot-state handoffs.", "Recovery behaviour handled missed detections, bad poses, and execution uncertainty.", "Lesson: logs, timestamps, and handoff checks matter as much as individual model accuracy."]
            )
        case .improvementPlan:
            return IntentFallbackAnswer(
                sayFirst: "If I had one more month, I would first improve LeoRover's robustness in real-robot retrieval. I would expand the evaluation beyond the initial trials, test lighting and occlusion failures, add confidence and spatial-consistency checks before acting on YOLOv8 detections, improve recovery after missed detections or failed grasps, and add calibration and latency diagnostics between perception, navigation, and manipulation.",
                keyPoints: ["First priority: broader LeoRover evaluation with more objects, starting positions, and failure cases.", "Improve perception robustness with confidence, spatial consistency, calibration, lighting, occlusion, and latency checks.", "Add stronger closed-loop recovery between perception, navigation, and manipulation after missed detections or failed grasps."]
            )
        case .whyRole:
            return IntentFallbackAnswer(
                sayFirst: "I’m interested in this role because it connects directly with my robotics, AI, and perception experience, and I want to keep building systems that move from prototypes into reliable real robot deployment while growing as an engineer.",
                keyPoints: ["Role alignment with robotics, AI, and perception.", "Interest in real robot deployment and deployed systems.", "Growth motivation in practical robotics engineering."]
            )
        case .skillComfort:
            return IntentFallbackAnswer(
                sayFirst: "I’m comfortable with Python and ROS2 from my robotics projects, especially perception pipelines, robot coordination, and experiment scripting. I have used C++ less than Python, but I understand its importance for performance-critical robotics systems and I’m actively improving it.",
                keyPoints: ["Python: strong for experiments, perception, and scripting.", "ROS2: used in robotics project pipelines and coordination.", "C++: honest learning area, important for performance-critical systems."]
            )
        case .candidateQuestions:
            return IntentFallbackAnswer(
                sayFirst: "I would ask how your team evaluates success when moving a robotics system from prototype demos to reliable real-world deployment.",
                keyPoints: ["What would success look like in the first three months?", "What are the biggest deployment challenges the robotics team is facing?", "How is ownership split between perception, autonomy, and product engineering?"]
            )
        case .interviewerQuestions:
            return IntentFallbackAnswer(
                sayFirst: "I would ask four questions: How would you describe what success looks like in the first three months? What are the biggest robotics deployment challenges the team is facing? How is the team structured across perception, autonomy, and product engineering? How much ownership would this role have over production workflows?",
                keyPoints: ["Ask about first-three-month success criteria.", "Ask about deployment challenges, data, and simulation infrastructure.", "Ask about team structure and production ownership."]
            )
        case .generic:
            return IntentFallbackAnswer(
                sayFirst: "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned.",
                keyPoints: ["Direct answer first.", "Concrete example from experience.", "Outcome or lesson learned."]
            )
        }
    }
}
