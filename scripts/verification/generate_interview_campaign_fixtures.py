#!/usr/bin/env python3
"""Generate deterministic, synthetic interview-campaign fixtures.

The generator contains no private candidate data and never fetches the network.
Public sources are provenance only; all role descriptions and questions are
paraphrased. Re-running this script must produce byte-for-byte stable JSON.
"""

from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import urlparse


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_ROOT = REPOSITORY_ROOT / "Tests" / "HirevaTests" / "Fixtures" / "InterviewCampaign"
ACCESS_DATE = "2026-08-31"
SEED = 20260831


def source(source_id: str, title: str, url: str, finding: str) -> dict:
    return {
        "id": source_id,
        "accessedAt": f"{ACCESS_DATE}T00:00:00Z",
        "problemID": "H24-ROLE-CORPUS",
        "sourceType": "official",
        "title": title,
        "url": url,
        "repository": "",
        "commitOrVersion": f"accessed-{ACCESS_DATE}",
        "license": "Copyright; facts paraphrased only",
        "relevantFiles": [
            "Tests/HirevaTests/Fixtures/InterviewCampaign/source_provenance.json",
            "Tests/HirevaTests/Fixtures/InterviewCampaign/role_taxonomy.json",
        ],
        "finding": finding,
        "appliesToHirevaBecause": "It informs a synthetic role competency or interview topic without supplying candidate history.",
        "doesNotApplyBecause": "The source does not prove any candidate experience and is not used as a live test dependency.",
        "codeCopied": False,
    }


SOURCES = [
    source("source-boston-dynamics-careers", "Boston Dynamics Careers", "https://bostondynamics.com/careers/", "Robotics roles combine research, software, hardware, testing, and reliable deployment in multidisciplinary teams."),
    source("source-nvidia-teams", "NVIDIA Teams and Areas of Work", "https://www.nvidia.com/en-us/about-nvidia/careers/teams-in-action/", "Robotics and AI work spans manipulation, navigation, perception, simulation, deep learning, and accelerated systems."),
    source("source-deepmind-careers", "Google DeepMind Careers", "https://deepmind.google/careers/", "Research engineers bridge theory and implementation, build distributed infrastructure, and run scaled experiments."),
    source("source-amazon-science-careers", "Amazon Science Careers", "https://www.amazon.science/careers", "Applied-science and robotics roles emphasize hypotheses, real and simulated evaluation, perception, control, and production transition."),
    source("source-apple-ml-work", "Apple Machine Learning Research: Work With Us", "https://machinelearning.apple.com/work-with-us", "ML opportunities span research, computer vision, systems, evaluation, and product-facing engineering."),
    source("source-microsoft-research-careers", "Microsoft Research Careers", "https://www.microsoft.com/en-us/research/careers/", "Research roles require rigorous methods, collaboration, publication-quality reasoning, and paths from research to products."),
    source("source-openai-infrastructure", "OpenAI Software Engineer, Infrastructure", "https://openai.com/careers/software-engineer-infrastructure-san-francisco/", "Infrastructure work covers distributed systems, reliability, observability, incident response, databases, and cloud foundations."),
    source("source-anthropic-careers", "Anthropic Jobs", "https://www.anthropic.com/careers/jobs", "Current roles cover research engineering, ML infrastructure, performance, safeguards, security, and research tooling."),
    source("source-stripe-backend", "Stripe Backend Engineer, Core Technology", "https://stripe.com/careers/listing/backend-engineer-core-technology/6042172", "Backend ownership includes reliability, scale, performance, cost, debugging, and core service infrastructure."),
    source("source-cockroach-careers", "Cockroach Labs Careers", "https://www.cockroachlabs.com/careers/", "Database engineering requires correctness, resilience, collaboration, and clear reasoning about distributed behavior."),
    source("source-cockroach-interview", "Cockroach Labs Open Interview Process", "https://www.cockroachlabs.com/careers/open-interview/", "Interview stages include coding, debugging, system design, and structured discussion of engineering decisions."),
    source("source-cockroach-distributed", "Cockroach Labs: Building Distributed Systems for the Real World", "https://www.cockroachlabs.com/blog/building-distributed-systems-for-scale-becca-taft/", "Distributed-system design must account for consistency, latency, failure, and operational edge cases."),
    source("source-cloudflare-careers", "Cloudflare Careers", "https://www.cloudflare.com/careers/", "Internet platform roles value ownership, transparent communication, security, and solving globally distributed systems problems."),
    source("source-apple-macos-swift", "Apple Senior Software Engineer, Swift - macOS", "https://jobs.apple.com/en-us/details/200658053-3956/senior-software-engineer-swift-macos", "Native macOS engineering spans Swift concurrency, SwiftUI/AppKit interop, process lifecycle, signing, entitlements, accessibility, and tests."),
    source("source-swift-concurrency", "The Swift Programming Language: Concurrency", "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/", "Swift concurrency defines task, actor, cancellation, and isolation concepts relevant to correctness questions."),
    source("source-apple-swiftui", "Apple SwiftUI Documentation", "https://developer.apple.com/documentation/swiftui", "SwiftUI work includes state-driven interfaces, lifecycle integration, and interoperability with platform frameworks."),
    source("source-airbnb-data-science", "Airbnb Data Science, Experimentation Platform", "https://careers.airbnb.com/positions/7790902/", "Data-science work emphasizes experimentation, causal inference, reusable measurement tooling, and business communication."),
    source("source-openai-emerging-talent", "OpenAI Emerging Talent", "https://openai.com/careers/emerging-talent/", "Early-career roles emphasize learning, applied engineering, research exposure, and meaningful ownership for candidates with zero to three years of experience."),
    source("source-microsoft-recent-graduate", "Microsoft Recent Graduate Opportunities", "https://careers.microsoft.com/v2/global/en/recentgraduate", "Graduate software roles combine fundamentals, troubleshooting, collaboration, delivery, and continuous learning."),
    source("source-nvidia-university", "NVIDIA Autonomous Vehicles and Robotics University Role Guide", "https://www.nvidia.com/content/dam/en-zz/Solutions/careers/university-recruiting/corporate-web-hr-ur-digital-flyer-job-description.pdf", "University role families include robotics, perception, simulation, operating systems, data structures, and deep-learning systems."),
    source("source-apple-privacy", "Apple Privacy Engineer", "https://jobs.apple.com/en-us/details/200663705/privacy-engineer-systems-experiences-apps-and-technologies", "Privacy engineering reduces user-data exposure through architecture, review, and cross-team guidance."),
    source("source-cloudflare-privacy", "Cloudflare Privacy and Data Protection", "https://www.cloudflare.com/trust-hub/privacy-and-data-protection/", "Privacy work includes data minimization, protection, transparency, regulatory obligations, and customer controls."),
    source("source-openai-ai-safety", "OpenAI Software Engineer, AI Safety", "https://openai.com/careers/software-engineer-ai-safety-san-francisco/", "Safety engineering builds robust systems to detect abuse, reduce deployment risk, and support trustworthy operation."),
    source("source-google-mlops", "Google Cloud MLOps Architecture", "https://cloud.google.com/architecture/mlops-continuous-delivery-and-automation-pipelines-in-machine-learning", "MLOps joins automated validation, reproducible pipelines, continuous delivery, monitoring, and controlled model promotion."),
    source("source-deepmind-robotics", "Google DeepMind Gemini Robotics", "https://deepmind.google/blog/gemini-robotics-brings-ai-into-the-physical-world/", "Embodied models require spatial reasoning, action, adaptation across embodiments, and explicit safety evaluation."),
    source("source-figure-careers", "Figure Careers", "https://www.figure.ai/careers", "A compact robotics company expects engineers to work across AI, engineering, design, and real hardware outcomes."),
    source("source-cognition-careers", "Cognition Careers", "https://cognition.com/careers", "A small applied-AI team lists product, research, ML infrastructure, security, reliability, and software ownership roles."),
    source("source-deepmind-accelerator", "Google DeepMind Robotics Accelerator", "https://deepmind.google/accelerators/robotics/", "Early-stage physical-AI companies must connect research, data, deployment, safety, and product constraints."),
    source("source-openai-data-science", "OpenAI Data Science Careers", "https://openai.com/careers/search/?q=Data+Scientist", "Data-science roles support experimentation, product decisions, model behavior analysis, and reusable measurement systems."),
    source("source-apple-security-jobs", "Apple Security and Privacy Jobs", "https://jobs.apple.com/en-us/search?team=security-and-privacy-SFTWR-SEC", "Security roles include supply-chain assurance, secure services, privacy compliance, and preventing unsafe code from shipping."),
]


COMMON_STAGES = [
    "recruiter_screen",
    "hiring_manager",
    "technical_fundamentals",
    "project_deep_dive",
    "system_design",
    "behavioral_star",
    "failure_and_debugging",
    "research_methodology",
    "trade_off_discussion",
    "panel_interview",
    "presentation_follow_up",
    "candidate_questions",
    "salary_visa_availability",
    "stress_challenge",
    "closing_discussion",
]


def role(
    slug: str,
    title: str,
    profile_id: str,
    responsibilities: list[str],
    competencies: list[str],
    sources: list[str],
    project: str,
    evaluation: str,
    failure: str,
    design: str,
    comparison: str,
    additional_stages: list[str],
) -> dict:
    return {
        "id": slug,
        "title": title,
        "core": True,
        "profileID": profile_id,
        "seniorities": ["graduate", "mid_level", "senior_research_depth"],
        "coreResponsibilities": responsibilities,
        "requiredCompetencies": competencies,
        "requiredStages": COMMON_STAGES,
        "additionalStages": additional_stages,
        "sourceProvenanceIDs": sources,
        "fixtureHints": {
            "project": project,
            "evaluation": evaluation,
            "failure": failure,
            "design": design,
            "comparison": comparison,
        },
    }


ROLES = [
    role("robotics_research_engineer", "Robotics Research Engineer", "profile-robotics-msc", ["form testable robotics hypotheses", "build manipulation experiments", "compare simulation and real-robot behavior", "document safety limitations"], ["perception", "planning", "control", "experimental validity", "sim-to-real reasoning", "latency and safety"], ["source-boston-dynamics-careers", "source-nvidia-teams", "source-amazon-science-careers"], "simulated manipulation pipeline", "the same held-out scenes and success criteria", "sensor uncertainty changed the grasp ranking", "a reproducible manipulation evaluation loop", "model-based and learned control", ["research_motivation", "experimental_validity", "future_research"]),
    role("robotics_software_engineer", "Robotics Software Engineer", "profile-robotics-msc", ["integrate robot software modules", "debug timing and sensor failures", "build simulation and hardware tests", "make recovery behavior observable"], ["C++ and Python", "ROS-style interfaces", "concurrency", "sensor integration", "real-time trade-offs", "failure recovery"], ["source-boston-dynamics-careers", "source-nvidia-teams", "source-figure-careers"], "simulated manipulation pipeline", "repeatable simulation and bench tests", "a delayed sensor update invalidated a plan", "a fault-tolerant robot software stack", "event-driven and fixed-rate control loops", ["coding_reasoning", "real_robot_evaluation", "sensor_failure"]),
    role("embodied_ai_vla_engineer", "Embodied AI / VLA Engineer", "profile-vla-researcher", ["train multimodal action models", "curate robot data", "evaluate generalization", "connect high-level reasoning to safe control"], ["vision-language-action models", "action representation", "robot learning", "dataset design", "generalization", "safety evaluation"], ["source-deepmind-robotics", "source-nvidia-teams", "source-amazon-science-careers"], "vision-language-action policy", "shared embodiments, tasks, and intervention criteria", "the policy overfit camera and workspace cues", "a guarded VLA inference and recovery pipeline", "diffusion and autoregressive action decoders", ["novelty", "domain_gap", "action_representation"]),
    role("computer_vision_engineer", "Computer Vision Engineer", "profile-cv-graduate", ["build perception pipelines", "define annotation policy", "measure generalization", "optimize inference and inspect failures"], ["detection and segmentation", "dataset quality", "metrics", "3D geometry", "inference profiling", "failure analysis"], ["source-nvidia-teams", "source-amazon-science-careers", "source-apple-ml-work"], "multi-camera defect-detection prototype", "a frozen test split with class-level error analysis", "rare lighting conditions caused false positives", "a monitored vision inference service", "two-stage and end-to-end detectors", ["dataset_sufficiency", "annotation_quality", "generalization"]),
    role("machine_learning_engineer", "Machine Learning Engineer", "profile-ml-engineer", ["build training pipelines", "evaluate models", "serve predictions", "monitor data and model behavior"], ["feature pipelines", "training reproducibility", "offline evaluation", "serving", "drift monitoring", "cost and latency"], ["source-deepmind-careers", "source-apple-ml-work", "source-anthropic-careers"], "reproducible ranking pipeline", "time-aware offline evaluation and shadow checks", "training-serving feature skew degraded ranking", "a reproducible train-evaluate-serve workflow", "pairwise and listwise ranking", ["data_pipeline", "deployment", "monitoring_and_drift"]),
    role("applied_scientist", "Applied Scientist", "profile-applied-scientist", ["turn product questions into hypotheses", "choose baselines", "design experiments", "communicate uncertainty and impact"], ["experimental design", "statistics", "machine learning", "baseline selection", "causal reasoning", "business relevance"], ["source-amazon-science-careers", "source-microsoft-research-careers", "source-deepmind-careers"], "synthetic recommendation experiment", "pre-registered metrics and confidence intervals", "a proxy metric diverged from the target outcome", "an experiment-to-decision workflow", "observational and randomized evaluation", ["hypothesis", "statistical_validity", "limitations"]),
    role("ai_research_scientist_phd", "AI Research Scientist / PhD Interview", "profile-applied-scientist", ["identify a research gap", "develop falsifiable methods", "compare strong baselines", "publish limitations and future work"], ["literature synthesis", "methodology", "falsifiability", "statistical validity", "novelty", "research communication"], ["source-deepmind-careers", "source-microsoft-research-careers", "source-apple-ml-work"], "synthetic recommendation experiment", "matched baselines, ablations, and uncertainty estimates", "the initial result disappeared under a stronger split", "a falsifiable research programme", "contrastive and generative objectives", ["paper_critique", "supervisor_fit", "threats_to_validity", "falsifiability"]),
    role("ai_infrastructure_mlops_engineer", "AI Infrastructure / MLOps Engineer", "profile-mlops-engineer", ["automate model delivery", "track artifacts and lineage", "monitor serving", "design rollback and recovery"], ["model registries", "CI/CD", "reproducibility", "observability", "security", "cost control"], ["source-openai-infrastructure", "source-anthropic-careers", "source-google-mlops"], "model promotion pipeline", "reproducible builds and staged deployment checks", "an unversioned feature artifact broke rollback", "a secure model delivery control plane", "blue-green and canary deployment", ["model_registry", "rollback", "reproducibility"]),
    role("backend_software_engineer", "Backend Software Engineer", "profile-backend-engineer", ["design versioned APIs", "model durable data", "operate services", "debug incidents"], ["API design", "relational databases", "concurrency", "observability", "testing", "deployment"], ["source-stripe-backend", "source-cockroach-careers", "source-cloudflare-careers"], "event-intake service", "deterministic replay and tail-latency checks", "duplicate delivery crossed a retry boundary", "an idempotent service and persistence model", "optimistic and pessimistic concurrency", ["api_design", "database", "incident_response"]),
    role("distributed_systems_engineer", "Distributed Systems Engineer", "profile-backend-engineer", ["reason about consistency", "design failure recovery", "measure capacity and latency", "operate distributed storage"], ["consensus concepts", "replication", "transactions", "fault tolerance", "performance", "observability"], ["source-cockroach-distributed", "source-stripe-backend", "source-openai-infrastructure"], "event-intake service", "fault injection with consistency and latency checks", "a retry raced a leadership change", "a recoverable distributed coordination layer", "linearizable and eventually consistent operations", ["consistency_model", "capacity_planning", "fault_tolerance"]),
    role("macos_swift_engineer", "macOS / Swift Engineer", "profile-swift-macos", ["ship native macOS features", "manage concurrency and lifecycle", "integrate AppKit and SwiftUI", "validate permissions and process cleanup"], ["Swift concurrency", "MainActor", "AppKit interop", "audio lifecycle", "TCC and signing", "memory and tests"], ["source-apple-macos-swift", "source-swift-concurrency", "source-apple-swiftui"], "local Swift prototype", "deterministic identity tests and bundled-app verification", "a cancelled task delivered a stale UI callback", "a privacy-preserving native macOS pipeline", "ScreenCaptureKit and microphone capture", ["main_actor", "tcc_identity", "process_management"]),
    role("systems_platform_engineer", "Systems / Platform Engineer", "profile-mlops-engineer", ["build shared platform primitives", "profile bottlenecks", "improve reliability", "support incident response"], ["operating systems", "networking", "storage", "performance profiling", "automation", "reliability"], ["source-openai-infrastructure", "source-cloudflare-careers", "source-nvidia-teams"], "model promotion pipeline", "load, failure, and resource-boundary tests", "file-descriptor pressure amplified retries", "an observable multi-tenant platform", "process and container isolation", ["operating_systems", "resource_management", "performance_analysis"]),
    role("data_scientist", "Data Scientist", "profile-data-scientist", ["define decision metrics", "audit data quality", "design experiments", "communicate uncertainty"], ["SQL", "statistics", "experimentation", "causal inference", "data quality", "stakeholder communication"], ["source-airbnb-data-science", "source-openai-data-science", "source-nvidia-teams"], "demand-forecasting analysis", "time-based validation and calibrated intervals", "target leakage inflated the first estimate", "a trustworthy measurement and decision workflow", "predictive and causal analysis", ["metric_definition", "data_leakage", "uncertainty"]),
    role("graduate_software_engineer", "Graduate Software Engineer", "profile-graduate-software", ["implement scoped features", "write tests", "debug with evidence", "learn and communicate clearly"], ["programming fundamentals", "data structures", "testing", "version control", "problem decomposition", "learning agility"], ["source-openai-emerging-talent", "source-microsoft-recent-graduate", "source-nvidia-university"], "small scheduling service", "unit tests and reproducible integration checks", "an edge case bypassed input validation", "a small testable service", "arrays and hash-based indexes", ["coding_reasoning", "learning_quickly", "fundamentals"]),
    role("founding_startup_ai_engineer", "Founding Engineer / Startup AI Engineer", "profile-ml-engineer", ["turn ambiguity into product increments", "own systems end to end", "balance research and delivery", "build safety and observability early"], ["product judgment", "full-stack ownership", "applied AI", "rapid validation", "reliability", "clear trade-offs"], ["source-cognition-careers", "source-figure-careers", "source-deepmind-accelerator"], "reproducible ranking pipeline", "small controlled pilots and explicit rollback criteria", "a fast prototype hid an unreliable dependency", "a minimal observable AI product loop", "custom models and managed APIs", ["ambiguous_task", "founder_trade_off", "zero_to_one_delivery"]),
    role("security_privacy_engineer", "Security / Privacy Engineer", "profile-swift-macos", ["threat-model systems", "minimize sensitive data", "verify controls", "respond to security failures"], ["threat modeling", "secure design", "privacy engineering", "logging discipline", "incident response", "supply-chain risk"], ["source-apple-privacy", "source-cloudflare-privacy", "source-openai-ai-safety"], "local Swift prototype", "canary scans and least-data test cases", "diagnostics retained more text than policy allowed", "a data-minimizing security boundary", "detection and prevention controls", ["privacy_review", "threat_model", "data_retention"]),
]


def profile(
    profile_id: str,
    name: str,
    role_families: list[str],
    prefix: str,
    statements: list[tuple[str, str]],
    skills: list[str],
    projects: list[str],
    metric: str,
    limitation: str,
    future_plan: str,
    not_experienced: list[str],
) -> dict:
    evidence = [
        {"id": f"{prefix}.e{index + 1}", "type": evidence_type, "statement": statement}
        for index, (evidence_type, statement) in enumerate(statements)
    ]
    return {
        "id": profile_id,
        "displayName": name,
        "synthetic": True,
        "roleFamilies": role_families,
        "candidateEvidenceIDs": [item["id"] for item in evidence],
        "verifiedStatements": evidence,
        "skills": skills,
        "projects": projects,
        "metrics": [metric],
        "limitations": [limitation],
        "futurePlans": [future_plan],
        "notExperiencedIn": not_experienced,
        "forbiddenClaims": [
            "deployed to one million users",
            "generated production revenue",
            "managed a team of twenty",
            "trained a foundation model from scratch",
        ],
        "workAuthorizationFacts": ["Work authorization must be answered only from explicit scenario facts; none are asserted in this fixture."],
        "availabilityFacts": ["Availability is unspecified and must not be invented."],
    }


PROFILES = [
    profile("profile-robotics-msc", "Synthetic Robotics MSc Candidate", ["robotics_research_engineer", "robotics_software_engineer"], "robotics", [("project", "Built a simulated manipulation pipeline with perception, planning, and bounded recovery"), ("experience", "Compared two grasping approaches on the same held-out scenes and success criteria"), ("skill", "Instrumented timing, sensor confidence, and recovery outcomes in repeatable bench tests")], ["Python", "C++", "robotics", "simulation", "evaluation"], ["Synthetic manipulation benchmark"], "The fixed synthetic benchmark contained 240 scenes; this is not a production-user metric.", "Has not operated a commercial robot fleet.", "Plans to extend evaluation to controlled hardware trials.", ["commercial robot deployment", "large-team management"]),
    profile("profile-vla-researcher", "Synthetic VLA Manipulation Researcher", ["embodied_ai_vla_engineer"], "vla", [("project", "Implemented a small vision-language-action policy for tabletop manipulation in simulation"), ("experience", "Evaluated action decoders across matched tasks, embodiments, and intervention criteria"), ("skill", "Isolated visual shortcut learning with camera and workspace perturbations")], ["PyTorch", "robot learning", "multimodal models", "evaluation"], ["Synthetic VLA decoder study"], "The study used simulated tasks and does not establish real-robot production performance.", "Has not trained a general foundation model from scratch.", "Plans controlled real-hardware validation with safety stops.", ["foundation-model pretraining", "production humanoid deployment"]),
    profile("profile-cv-graduate", "Synthetic Computer Vision Graduate", ["computer_vision_engineer"], "vision", [("project", "Built a multi-camera defect-detection prototype on a licensed synthetic image set"), ("experience", "Created a frozen split and reported class-level precision, recall, and calibration"), ("skill", "Isolated rare-lighting false positives through inference profiling and annotation checks")], ["Python", "computer vision", "annotation", "model evaluation"], ["Synthetic visual inspection prototype"], "Results are limited to the fixed fixture dataset.", "Has not owned a global production vision service.", "Plans to validate domain shift before any deployment claim.", ["global deployment", "customer-scale inference"]),
    profile("profile-ml-engineer", "Synthetic ML Engineer", ["machine_learning_engineer", "founding_startup_ai_engineer"], "ml", [("project", "Built a reproducible ranking pipeline with versioned features and model artifacts"), ("experience", "Compared pairwise and listwise objectives with time-aware offline evaluation"), ("skill", "Instrumented training-serving skew with shadow requests and feature checksums")], ["Python", "ML pipelines", "ranking", "serving", "monitoring"], ["Synthetic ranking and serving pipeline"], "Only offline and shadow results are documented.", "Has not claimed revenue or customer adoption.", "Plans a guarded pilot with rollback criteria.", ["commercial impact", "large-scale people leadership"]),
    profile("profile-applied-scientist", "Synthetic Applied Scientist", ["applied_scientist", "ai_research_scientist_phd"], "science", [("project", "Designed a synthetic recommendation experiment around a falsifiable hypothesis"), ("experience", "Pre-registered primary metrics, baselines, and confidence intervals before analysis"), ("skill", "Tested the initial conclusion with a stronger split that removed the measured effect")], ["experimental design", "statistics", "machine learning", "research communication"], ["Synthetic recommendation study"], "The experiment is synthetic and has no business-impact claim.", "Has not published this fixture study or deployed it commercially.", "Plans replication on an independently sampled fixture set.", ["commercial deployment", "unsupported publication claims"]),
    profile("profile-backend-engineer", "Synthetic Backend Engineer", ["backend_software_engineer", "distributed_systems_engineer"], "backend", [("project", "Built an event-intake service with versioned APIs and idempotency keys"), ("experience", "Measured deterministic replay, transaction boundaries, and tail latency under injected failures"), ("skill", "Debugged duplicate delivery across a retry and persistence boundary")], ["Swift", "Kotlin", "SQL", "distributed systems", "observability"], ["Synthetic event-intake service"], "The service ran only in an isolated test environment.", "Has not operated a global customer platform.", "Plans staged load and recovery tests before wider use.", ["global operations", "enterprise customer ownership"]),
    profile("profile-swift-macos", "Synthetic Swift and macOS Engineer", ["macos_swift_engineer", "security_privacy_engineer"], "swift", [("project", "Built a local Swift prototype that reconciles transcript events and isolates test data"), ("experience", "Added deterministic question, generation, session, and context identity checks"), ("skill", "Tested bundled-app process cleanup and isolated a stale callback after cancellation")], ["Swift", "SwiftUI", "AppKit", "Swift concurrency", "SQLite", "privacy testing"], ["Synthetic local macOS assistant prototype"], "No notarization, public distribution, or production-user claim is part of the profile.", "Has not shipped a notarized commercial release.", "Plans to validate Developer ID signing and notarization separately.", ["notarized public distribution", "commercial adoption"]),
    profile("profile-mlops-engineer", "Synthetic MLOps Engineer", ["ai_infrastructure_mlops_engineer", "systems_platform_engineer"], "mlops", [("project", "Built a model promotion pipeline with immutable artifact identifiers"), ("experience", "Used staged checks for reproducibility, serving health, and rollback readiness"), ("skill", "Tested rollback recovery after an unversioned feature artifact caused failure")], ["CI/CD", "model registry", "containers", "observability", "security"], ["Synthetic model delivery control plane"], "The pipeline was validated locally rather than on a public cloud fleet.", "Has not run hyperscale production infrastructure.", "Plans capacity and recovery validation under controlled load.", ["hyperscale operations", "unverified cloud cost savings"]),
    profile("profile-data-scientist", "Synthetic Data Scientist", ["data_scientist"], "data", [("project", "Built a demand-forecasting analysis with time-based validation"), ("experience", "Defined decision metrics and calibrated uncertainty intervals before model comparison"), ("skill", "Tested feature availability and isolated target leakage at prediction time")], ["SQL", "Python", "statistics", "experimentation", "communication"], ["Synthetic demand-forecasting analysis"], "The data and decisions are synthetic and do not represent a real business.", "Has not claimed causal impact from observational data.", "Plans a prospective evaluation before operational use.", ["real revenue impact", "unsupported causal conclusions"]),
    profile("profile-graduate-software", "Synthetic Graduate Software Engineer", ["graduate_software_engineer"], "graduate", [("project", "Implemented a small scheduling service with explicit input validation"), ("experience", "Added unit and integration tests for boundary and retry cases"), ("skill", "Debugged an invalid-state edge case using a minimal reproducible example")], ["Python", "Swift", "data structures", "testing", "Git"], ["Synthetic scheduling service"], "Experience is limited to coursework and controlled projects.", "Has not led a large engineering team or operated a global service.", "Plans to deepen production observability and deployment skills.", ["large-team leadership", "global service operations"]),
]


ROLE_BY_ID = {item["id"]: item for item in ROLES}
PROFILE_BY_ID = {item["id"]: item for item in PROFILES}


def first_person(statement: str) -> str:
    return f"I {statement[0].lower()}{statement[1:]}"


def sentence_count(text: str) -> int:
    return sum(text.count(mark) for mark in ".?!")


def build_opportunities() -> list[dict]:
    opportunities = []
    seniority_titles = {
        "graduate": "Graduate",
        "mid_level": "Mid-level",
        "senior_research_depth": "Senior / Research-depth",
    }
    for role_item in ROLES:
        for index, seniority in enumerate(role_item["seniorities"], start=1):
            opportunity_id = f"opportunity-{role_item['id']}-{index:02d}"
            responsibilities = role_item["coreResponsibilities"]
            competencies = role_item["requiredCompetencies"]
            evidence = [
                {"id": f"{opportunity_id}.responsibility", "type": "responsibility", "statement": f"Own {responsibilities[(index - 1) % len(responsibilities)]}."},
                {"id": f"{opportunity_id}.competency", "type": "required_skill", "statement": f"Demonstrate {competencies[(index + 1) % len(competencies)]} with explicit evidence."},
                {"id": f"{opportunity_id}.success", "type": "evaluation_criterion", "statement": f"Success requires reproducible reasoning about {role_item['fixtureHints']['evaluation']}."},
            ]
            opportunities.append({
                "id": opportunity_id,
                "roleFamilyID": role_item["id"],
                "roleFamily": role_item["title"],
                "title": f"{seniority_titles[seniority]} {role_item['title']}",
                "seniority": seniority,
                "synthetic": True,
                "coreResponsibilities": responsibilities,
                "requiredCompetencies": competencies,
                "opportunityEvidence": evidence,
                "sourceProvenanceIDs": role_item["sourceProvenanceIDs"],
                "forbiddenExperienceClaims": ["A job requirement is not candidate experience.", "Seniority does not prove people-management experience."],
            })
    return opportunities


OPPORTUNITIES = build_opportunities()
OPPORTUNITY_BY_ID = {item["id"]: item for item in OPPORTUNITIES}


OPENING_PHENOMENA = [
    "direct_question", "imperative_question", "long_preamble", "question_without_punctuation",
    "nested_question", "negative_question", "leading_question", "hypothetical",
    "counterfactual", "multi_part_question",
]
RECOGNITION_PATTERNS = ["partial_final", "stable_partial", "cumulative_replay", "self_correction", "interviewer_correction"]
FOLLOW_UP_PHENOMENA = ["rapid_follow_up", "pronoun_reference", "elliptical_reference", "single_word_follow_up"]
ADVERSARIAL_PHENOMENA = ["false_premise", "missing_evidence", "challenge_question", "conflicting_evidence", "leading_question"]
FINAL_PHENOMENA = ["system_design", "technical_comparison", "behavioral_star", "trade_off_discussion", "research_methodology", "salary_and_visa", "panel", "presentation_follow_up", "unicode", "code_switching"]


def opening_question(role_item: dict, focus: str, session_index: int) -> str:
    title = role_item["title"]
    project_name = role_item["fixtureHints"]["project"]
    templates = [
        f"What evidence from your {project_name} best prepares you for this {title} role?",
        f"Walk me through the part of your {project_name} that is evidence for {focus}.",
        f"Before we discuss the team, could you explain how your {project_name} prepared you for {focus}?",
        f"how does your {project_name} demonstrate {focus}",
        f"When you describe {focus}, what did you personally implement in the {project_name}?",
        f"What limitation in your {project_name} matters most for {focus}?",
        f"You already mastered {focus}, so which result proves it?",
        f"If the {project_name} had to support {focus} tomorrow, how would your evidence guide the first step?",
        f"If your original approach to {focus} had failed completely, what evidence would you preserve?",
        f"Describe your {project_name}, explain your personal contribution, and tell me how it relates to {focus}?",
    ]
    return templates[session_index]


def candidate_turn(role_item: dict, focus: str, session_index: int) -> tuple[str, list[str]]:
    variants = [
        (f"My main contribution to the {role_item['fixtureHints']['project']} was the documented evaluation work on {focus}.", ["candidate_microphone_speech"]),
        (f"Could you tell me more about how the team approaches {focus}?", ["candidate_microphone_speech", "candidate_question_to_panel"]),
        (f"I would like to clarify one point about {focus} before continuing.", ["candidate_microphone_speech", "candidate_correction"]),
        (f"In this presentation I will separate my contribution from the team context around {focus}.", ["candidate_microphone_speech", "candidate_presentation"]),
    ]
    return variants[session_index % len(variants)]


def follow_up_question(role_item: dict, focus: str, session_index: int) -> str:
    variants = [
        f"What was the hardest failure when you applied that approach to {focus}?",
        f"Why did that result matter for {focus}?",
        f"How did you verify that under the same conditions for {focus}?",
        "Why?",
    ]
    return variants[session_index % len(variants)]


def closing_question(role_item: dict, focus: str, session_index: int) -> str:
    hints = role_item["fixtureHints"]
    variants = [
        f"How would you design {hints['design']} for {focus}, and how would you test recovery?",
        f"Compare {hints['comparison']} for {focus}.",
        f"Tell me about a difficult decision involving {focus}, and explain what you learned.",
        f"Which trade-off would you make first in {hints['design']} when {focus} is constrained?",
        f"What result would falsify your approach to {focus}, and what baseline would you use?",
        f"What work-authorization or availability facts can you state with evidence for this {role_item['title']} process?",
        f"Interviewer B asks: how should the recovery design change when {focus} fails after Interviewer A's architecture question?",
        f"After the candidate presentation, which evidence would you inspect before accepting the claim about {focus}?",
        f"How would you test {focus} when the transcript contains naïve Unicode terms such as café and résumé?",
        f"How would you explain the {focus} trade-off when the interviewer asks 请用 English 回答?",
    ]
    return variants[session_index]


def make_turn(
    *,
    scenario_id: str,
    session_id: str,
    turn_index: int,
    role_item: dict,
    profile_item: dict,
    opportunity: dict,
    stage: str,
    channel: str,
    speaker: str,
    speaker_label: str,
    utterance: str,
    partials: list[str],
    trigger: bool,
    intent: str,
    phenomena: list[str],
    allowed_evidence: list[str],
    required_concepts: list[str],
    expected_answer: str | None,
    expected_primary_question: str | None = None,
    rapid: bool = False,
    recognition_pattern: str = "final",
    previous_relevant: list[str] | None = None,
    previous_irrelevant: list[str] | None = None,
    cancelled_generations: list[str] | None = None,
) -> dict:
    question_id = f"question-{scenario_id}" if trigger else None
    generation_id = f"generation-{scenario_id}" if trigger else None
    snapshot_id = f"snapshot-{session_id}-{profile_item['id']}-{opportunity['id']}"
    opportunity_evidence_ids = [item["id"] for item in opportunity["opportunityEvidence"]]
    all_other_evidence = [
        evidence_id
        for other in PROFILES
        if other["id"] != profile_item["id"]
        for evidence_id in other["candidateEvidenceIDs"][:1]
    ]
    result = {
        "scenarioID": scenario_id,
        "sessionID": session_id,
        "turnIndex": turn_index,
        "roleFamily": role_item["title"],
        "roleFamilyID": role_item["id"],
        "seniority": opportunity["seniority"],
        "interviewStage": stage,
        "candidateProfileID": profile_item["id"],
        "opportunityContextID": opportunity["id"],
        "contextSnapshotID": snapshot_id,
        "channel": channel,
        "speaker": speaker,
        "speakerLabel": speaker_label,
        "rawUtterance": utterance,
        "partialUtterances": partials,
        "recognitionPattern": recognition_pattern,
        "expectedASRSource": "local_parakeet",
        "expectedProviderSource": "ollama_qwen" if trigger else None,
        "dialoguePhenomena": phenomena,
        "expectedShouldTrigger": trigger,
        "expectedQuestionCount": 1 if trigger else 0,
        "expectedPrimaryQuestion": (expected_primary_question or utterance) if trigger else None,
        "expectedIntent": intent,
        "expectedDialoguePhase": "interview",
        "allowedCandidateEvidenceIDs": allowed_evidence,
        "allowedOpportunityEvidenceIDs": opportunity_evidence_ids if trigger else [],
        "requiredConcepts": required_concepts,
        "forbiddenCandidateEvidenceIDs": all_other_evidence,
        "forbiddenClaims": profile_item["forbiddenClaims"],
        "mustNotMention": ["CV", "JD", "RAG", "prompt", "Qwen", "metadata"],
        "answerStyle": {"firstPerson": True, "spoken": True, "maxSentences": 4},
        "expectedAnswer": expected_answer,
        "expectedPersistenceCount": 1 if trigger else 0,
        "sourceProvenanceIDs": role_item["sourceProvenanceIDs"],
        "rapidFollowUp": rapid,
        "previousRelevantTurnIDs": previous_relevant or [],
        "previousIrrelevantTurnIDs": previous_irrelevant or [],
        "expectedReferenceResolution": (previous_relevant or [None])[-1] if previous_relevant else None,
        "expectedNewQuestionIdentity": {
            "questionID": question_id,
            "generationID": generation_id,
            "sessionID": session_id,
            "contextSnapshotID": snapshot_id,
        } if trigger else None,
        "expectedCancelledGenerationIDs": cancelled_generations or [],
    }
    if expected_answer is not None:
        assert 1 <= sentence_count(expected_answer) <= 4
    return result


def build_sessions_and_turns() -> tuple[list[dict], list[dict]]:
    sessions: list[dict] = []
    turns: list[dict] = []
    opportunity_by_role_and_level = {
        (item["roleFamilyID"], item["seniority"]): item for item in OPPORTUNITIES
    }
    for role_index, role_item in enumerate(ROLES):
        profile_item = PROFILE_BY_ID[role_item["profileID"]]
        evidence = profile_item["verifiedStatements"]
        focuses = [f"the requirement to {item}" for item in role_item["coreResponsibilities"]] + [
            f"the competency of {item}" for item in role_item["requiredCompetencies"]
        ]
        stage_pool = role_item["requiredStages"] + role_item["additionalStages"]
        for session_index in range(10):
            seniority = role_item["seniorities"][session_index % 3]
            opportunity = opportunity_by_role_and_level[(role_item["id"], seniority)]
            session_id = f"campaign-{role_item['id']}-{session_index + 1:02d}"
            focus = focuses[session_index]
            sessions.append({
                "sessionID": session_id,
                "roleFamilyID": role_item["id"],
                "candidateProfileID": profile_item["id"],
                "opportunityContextID": opportunity["id"],
                "initialMode": "auto",
                "synthetic": True,
                "focus": focus,
                "sourceProvenanceIDs": role_item["sourceProvenanceIDs"],
            })
            ids = [f"campaign-{role_index + 1:02d}-{session_index + 1:02d}-{turn_index:02d}" for turn_index in range(1, 9)]
            stages = [stage_pool[(session_index * 8 + offset) % len(stage_pool)] for offset in range(8)]
            opening = opening_question(role_item, focus, session_index)
            opening_primary = opening
            if session_index == 2:
                opening_primary = opening.split(", ", maxsplit=1)[1]
                opening_primary = opening_primary[0].upper() + opening_primary[1:]
            answer_1 = f"{first_person(evidence[0]['statement'])}. {first_person(evidence[1]['statement'])}. Together, those documented results are the evidence I would relate to {focus}."
            turns.append(make_turn(scenario_id=ids[0], session_id=session_id, turn_index=1, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[0], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer A", utterance=opening, partials=[], trigger=True, intent="background_and_fit", phenomena=[OPENING_PHENOMENA[session_index]], allowed_evidence=[evidence[0]["id"], evidence[1]["id"]], required_concepts=[role_item["fixtureHints"]["project"]], expected_answer=answer_1, expected_primary_question=opening_primary))

            candidate_text, candidate_phenomena = candidate_turn(role_item, focus, session_index)
            turns.append(make_turn(scenario_id=ids[1], session_id=session_id, turn_index=2, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[1], channel="microphone", speaker="candidate", speaker_label="Candidate", utterance=candidate_text, partials=[], trigger=False, intent="candidate_speech", phenomena=candidate_phenomena, allowed_evidence=[], required_concepts=[], expected_answer=None, previous_relevant=[ids[0]]))

            evaluation_question = f"How did you evaluate your work against {focus} in the {role_item['fixtureHints']['project']}?"
            words = evaluation_question.split()
            first_cut = max(3, len(words) // 3)
            second_cut = min(len(words) - 1, max(first_cut + 1, len(words) - 2))
            partials = [" ".join(words[:first_cut]), " ".join(words[:second_cut])]
            answer_3 = f"{first_person(evidence[1]['statement'])}. I would use {role_item['fixtureHints']['evaluation']} to inspect, test, and validate {focus} in the {role_item['fixtureHints']['project']}."
            recognition_pattern = RECOGNITION_PATTERNS[session_index % len(RECOGNITION_PATTERNS)]
            turns.append(make_turn(scenario_id=ids[2], session_id=session_id, turn_index=3, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[2], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer A", utterance=evaluation_question, partials=partials, trigger=True, intent="project_evaluation", phenomena=["partial_asr", "final_asr", recognition_pattern], allowed_evidence=[evidence[1]["id"]], required_concepts=[role_item["fixtureHints"]["evaluation"]], expected_answer=answer_3, recognition_pattern=recognition_pattern, previous_relevant=[ids[0]], previous_irrelevant=[ids[1]]))

            follow_up = follow_up_question(role_item, focus, session_index)
            follow_up_primary = follow_up
            follow_up_variant = session_index % len(FOLLOW_UP_PHENOMENA)
            if follow_up_variant == 0:
                answer_4 = f"The hardest documented issue is the one addressed by this work: {first_person(evidence[2]['statement'])}. I would keep {focus} within that evidenced scope."
                follow_up_evidence = [evidence[2]["id"]]
                follow_up_concepts = [evidence[2]["statement"]]
            elif follow_up_variant == 2:
                answer_4 = f"{first_person(evidence[1]['statement'])}. I would verify the same result for {focus} with {role_item['fixtureHints']['evaluation']}."
                follow_up_evidence = [evidence[1]["id"]]
                follow_up_concepts = [role_item["fixtureHints"]["evaluation"]]
            else:
                answer_4 = f"That evaluation mattered for {focus} because it used {role_item['fixtureHints']['evaluation']}. {first_person(evidence[1]['statement'])}."
                follow_up_evidence = [evidence[1]["id"]]
                follow_up_concepts = [role_item["fixtureHints"]["evaluation"]]
            if follow_up_variant == 3:
                follow_up_primary = f"Why did your evaluation against {focus} in the {role_item['fixtureHints']['project']} matter?"
            turns.append(make_turn(scenario_id=ids[3], session_id=session_id, turn_index=4, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[3], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer B" if session_index % 2 else "Interviewer A", utterance=follow_up, partials=[], trigger=True, intent="rapid_failure_follow_up", phenomena=["rapid_follow_up", FOLLOW_UP_PHENOMENA[follow_up_variant], "interruption" if session_index % 2 else "pronoun_reference"], allowed_evidence=follow_up_evidence, required_concepts=follow_up_concepts, expected_answer=answer_4, expected_primary_question=follow_up_primary, rapid=True, previous_relevant=[ids[2]], previous_irrelevant=[ids[1]], cancelled_generations=[f"generation-{ids[2]}"]))

            small_talk_variants = [
                f"Great, thank you; we will move beyond {focus}.",
                "Can you hear me clearly?",
                f"Take your time before the next {role_item['title']} topic.",
                f"The team uses a hybrid model while discussing {focus}.",
                f"Okay, let's move on from {focus}.",
            ]
            turns.append(make_turn(scenario_id=ids[4], session_id=session_id, turn_index=5, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[4], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer A", utterance=small_talk_variants[session_index % len(small_talk_variants)], partials=[], trigger=False, intent="small_talk_or_logistics", phenomena=["small_talk", "audio_check" if session_index % 5 == 1 else "statement"], allowed_evidence=[], required_concepts=[], expected_answer=None, previous_relevant=[ids[3]]))

            premise_question = f"You deployed the {role_item['fixtureHints']['project']} to one million production users and generated revenue while meeting {focus}, correct?"
            answer_6 = f"I do not have evidence for that production-scale claim or for any revenue result involving {focus}. {first_person(evidence[0]['statement'])}. I would keep the answer limited to that documented synthetic work."
            turns.append(make_turn(scenario_id=ids[5], session_id=session_id, turn_index=6, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[5], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer B", utterance=premise_question, partials=[], trigger=True, intent="false_premise_and_missing_evidence", phenomena=["missing_evidence", "adversarial", ADVERSARIAL_PHENOMENA[session_index % len(ADVERSARIAL_PHENOMENA)]], allowed_evidence=[evidence[0]["id"]], required_concepts=["do not have evidence"], expected_answer=answer_6, previous_relevant=[ids[0]], previous_irrelevant=[ids[4]]))

            statement = f"Interviewer A notes that {focus} is important, and Interviewer B will now narrow the discussion to recovery behavior."
            turns.append(make_turn(scenario_id=ids[6], session_id=session_id, turn_index=7, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[6], channel="systemAudio", speaker="interviewer", speaker_label="Panel transition", utterance=statement, partials=[], trigger=False, intent="panel_statement", phenomena=["two_interviewers", "statement", "panel_transition"], allowed_evidence=[], required_concepts=[], expected_answer=None, previous_relevant=[ids[5]]))

            final_question = closing_question(role_item, focus, session_index)
            final_primary = final_question
            if session_index == 6:
                final_primary = final_question.split(": ", maxsplit=1)[1]
                final_primary = final_primary[0].upper() + final_primary[1:]
            elif session_index == 7:
                final_primary = final_question.split(", ", maxsplit=1)[1]
                final_primary = final_primary[0].upper() + final_primary[1:]
            if session_index == 0:
                answer_8 = f"I would design {role_item['fixtureHints']['design']} for {focus} as a system with explicit component boundaries. I would inspect, test, and validate failure recovery with {role_item['fixtureHints']['evaluation']}."
                final_concepts = [role_item["fixtureHints"]["design"], "failure recovery"]
            elif session_index == 1:
                answer_8 = f"I would compare {role_item['fixtureHints']['comparison']} for {focus}, measuring each alternative with {role_item['fixtureHints']['evaluation']}. I would choose the alternative with the stronger documented result."
                final_concepts = [role_item["fixtureHints"]["comparison"], role_item["fixtureHints"]["evaluation"]]
            elif session_index == 2:
                answer_8 = f"I do not have evidence for a completed difficult decision about {focus}, so I would not invent one. I would test the options, choose an action, and measure the result before answering with a documented example."
                final_concepts = ["do not have evidence", "decision"]
            elif session_index == 3:
                answer_8 = f"I would choose the first trade-off in {role_item['fixtureHints']['design']} for {focus} by balancing reliability, latency, and complexity. I would test the decision with {role_item['fixtureHints']['evaluation']}."
                final_concepts = [role_item["fixtureHints"]["design"], "trade-off", "choose"]
            elif session_index == 4:
                answer_8 = f"I would use {role_item['fixtureHints']['evaluation']} as the baseline for {focus}. I would reject the approach if the result failed that baseline, because that would falsify the claim."
                final_concepts = [role_item["fixtureHints"]["evaluation"], "baseline", "falsify"]
            elif session_index == 5:
                answer_8 = "I do not have evidence for a specific work-authorization or availability answer in this synthetic profile. I would verify both facts directly rather than invent them."
                final_concepts = ["do not have evidence", "work-authorization", "availability"]
            elif session_index == 6:
                answer_8 = f"I would redesign {role_item['fixtureHints']['design']} for {focus} with an explicit failure boundary and recovery path between system components. I would inspect, test, and validate the handoff with {role_item['fixtureHints']['evaluation']}."
                final_concepts = [role_item["fixtureHints"]["design"], "failure", "recovery"]
            elif session_index == 7:
                answer_8 = f"I would inspect {role_item['fixtureHints']['evaluation']} before accepting the claim about {focus}. I would require a reproducible test result and reject the claim if the evidence did not hold."
                final_concepts = [role_item["fixtureHints"]["evaluation"], "evidence"]
            elif session_index == 8:
                answer_8 = f"I would test {focus} with naïve, café, and résumé inputs, then inspect normalized Unicode boundaries and validate the result. I would keep the test deterministic across the system pipeline."
                final_concepts = ["naïve", "café", "résumé"]
            else:
                answer_8 = f"I would explain the trade-off for {focus} in English, compare the alternatives, and choose based on reliability, latency, and {role_item['fixtureHints']['evaluation']}."
                final_concepts = ["English", "trade-off"]
            turns.append(make_turn(scenario_id=ids[7], session_id=session_id, turn_index=8, role_item=role_item, profile_item=profile_item, opportunity=opportunity, stage=stages[7], channel="systemAudio", speaker="interviewer", speaker_label="Interviewer B", utterance=final_question, partials=[], trigger=True, intent="design_trade_off", phenomena=[FINAL_PHENOMENA[session_index], "panel_interview"], allowed_evidence=[], required_concepts=final_concepts, expected_answer=answer_8, expected_primary_question=final_primary, previous_relevant=[ids[5]], previous_irrelevant=[ids[6]]))
    return sessions, turns


SESSIONS, TURNS = build_sessions_and_turns()


def normalized_utterance(value: str) -> str:
    return " ".join("".join(character.lower() if character.isalnum() else " " for character in value).split())


def validate() -> dict:
    source_ids = {item["id"] for item in SOURCES}
    profile_ids = {item["id"] for item in PROFILES}
    opportunity_ids = {item["id"] for item in OPPORTUNITIES}
    session_ids = {item["sessionID"] for item in SESSIONS}
    assert len(SOURCES) == len(source_ids)
    assert len(ROLES) == 16
    assert len(PROFILES) == len(profile_ids) == 10
    assert len(OPPORTUNITIES) == len(opportunity_ids) == 48
    assert len(SESSIONS) == len(session_ids) == 160
    assert len(TURNS) == 1280
    assert len({item["scenarioID"] for item in TURNS}) == 1280
    # Identical short utterances such as "Why?" and audio checks are meaningful
    # in different frozen contexts. What we reject is counting punctuation-only
    # variants as distinct inside the same role, level, stage, and context.
    scenario_keys = {
        (
            normalized_utterance(item["rawUtterance"]),
            item["roleFamilyID"],
            item["seniority"],
            item["interviewStage"],
            item["candidateProfileID"],
            item["opportunityContextID"],
        )
        for item in TURNS
    }
    assert len(scenario_keys) == 1280
    for role_item in ROLES:
        assert len(role_item["sourceProvenanceIDs"]) >= 3
        assert set(role_item["sourceProvenanceIDs"]).issubset(source_ids)
        hosts = {urlparse(next(item["url"] for item in SOURCES if item["id"] == source_id)).netloc for source_id in role_item["sourceProvenanceIDs"]}
        assert len(hosts) >= 3
    for turn in TURNS:
        assert turn["sessionID"] in session_ids
        assert turn["candidateProfileID"] in profile_ids
        assert turn["opportunityContextID"] in opportunity_ids
        profile_item = PROFILE_BY_ID[turn["candidateProfileID"]]
        assert set(turn["allowedCandidateEvidenceIDs"]).issubset(profile_item["candidateEvidenceIDs"])
        assert set(turn["allowedCandidateEvidenceIDs"]).isdisjoint(turn["forbiddenCandidateEvidenceIDs"])
        assert turn["expectedPersistenceCount"] == (1 if turn["expectedShouldTrigger"] else 0)
        if turn["expectedShouldTrigger"]:
            assert turn["expectedAnswer"]
            assert turn["expectedNewQuestionIdentity"]
        else:
            assert turn["expectedAnswer"] is None
            assert turn["expectedNewQuestionIdentity"] is None
    counts = {
        "roleFamilies": len(ROLES),
        "candidateProfiles": len(PROFILES),
        "opportunityContexts": len(OPPORTUNITIES),
        "sessions": len(SESSIONS),
        "automatedTurns": len(TURNS),
        "positiveTurns": sum(item["expectedShouldTrigger"] for item in TURNS),
        "negativeTurns": sum(not item["expectedShouldTrigger"] for item in TURNS),
        "rapidTurns": sum(item["rapidFollowUp"] for item in TURNS),
        "partialFinalReplayTurns": sum(bool(item["partialUtterances"]) for item in TURNS),
        "missingEvidenceAdversarialTurns": sum("adversarial" in item["dialoguePhenomena"] for item in TURNS),
        "distinctNormalizedUtterances": len({normalized_utterance(item["rawUtterance"]) for item in TURNS}),
        "distinctFrozenContextScenarioKeys": len(scenario_keys),
    }
    assert counts["positiveTurns"] >= 700
    assert counts["negativeTurns"] >= 300
    assert counts["rapidTurns"] >= 100
    assert counts["partialFinalReplayTurns"] >= 100
    assert counts["missingEvidenceAdversarialTurns"] >= 100
    return counts


def write_json(name: str, payload: object) -> None:
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    destination = OUTPUT_ROOT / name
    destination.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    counts = validate()
    role_taxonomy = {
        "synthetic": True,
        "accessDate": ACCESS_DATE,
        "minimumIndependentSourcesPerRole": 3,
        "coreRoleFamilies": ROLES,
        "additionalExplorationFamilies": [
            "SLAM Engineer", "Controls Engineer", "Simulation Engineer", "Research Assistant",
            "Technical Consultant", "Solution Architect", "Engineering Manager", "Founder's Associate technical interview",
        ],
    }
    manifest = {
        "campaignFixtureVersion": 1,
        "synthetic": True,
        "containsRealPersonalData": False,
        "randomSeed": SEED,
        "generatedDeterministically": True,
        "counts": counts,
        "files": [
            "source_provenance.json", "role_taxonomy.json", "candidate_profiles.json",
            "opportunity_contexts.json", "interview_sessions.json", "dialogue_turns.json",
        ],
        "contentPolicy": {
            "syntheticMockInterviewsOnly": True,
            "noThirdPartyInterviewRecordings": True,
            "noEmployerRuleEvasion": True,
            "noStealthOrAntiDetectionFeatures": True,
        },
    }
    write_json("source_provenance.json", {"synthetic": True, "accessDate": ACCESS_DATE, "sources": SOURCES})
    write_json("role_taxonomy.json", role_taxonomy)
    write_json("candidate_profiles.json", {"synthetic": True, "profiles": PROFILES})
    write_json("opportunity_contexts.json", {"synthetic": True, "opportunities": OPPORTUNITIES})
    write_json("interview_sessions.json", {"synthetic": True, "sessions": SESSIONS})
    write_json("dialogue_turns.json", {"synthetic": True, "turns": TURNS})
    write_json("campaign_manifest.json", manifest)
    print(json.dumps(counts, sort_keys=True))


if __name__ == "__main__":
    main()
