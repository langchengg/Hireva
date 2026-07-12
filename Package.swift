// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "InterviewCopilotMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "InterviewCopilotMacCore", targets: ["InterviewCopilotMac"]),
        .executable(name: "InterviewCopilotMac", targets: ["InterviewCopilotMacRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3")
    ],
    targets: [
        .target(
            name: "InterviewCopilotMac",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/InterviewCopilotMac",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "InterviewCopilotMacRunner",
            dependencies: [
                .target(name: "InterviewCopilotMac")
            ],
            path: "Sources/InterviewCopilotMacRunner"
        ),
        .testTarget(
            name: "InterviewCopilotMacTests",
            dependencies: [
                .target(name: "InterviewCopilotMac")
            ],
            path: "Tests/InterviewCopilotMacTests",
            resources: [
                .process("Fixtures/backend_candidate_profile.json"),
                .process("Fixtures/backend_opportunity_context.json"),
                .process("Fixtures/biomedical_candidate_profile.json"),
                .process("Fixtures/cybersecurity_candidate_profile.json"),
                .process("Fixtures/data_scientist_candidate_profile.json"),
                .process("Fixtures/product_manager_candidate_profile.json"),
                .process("Fixtures/robotics_phd_candidate_profile.json"),
                .process("Fixtures/robotics_phd_opportunity_context.json"),
                .copy("Fixtures/WebSourcedSyntheticContexts")
            ]
        )
    ]
)
