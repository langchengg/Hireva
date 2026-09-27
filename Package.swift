// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Hireva",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HirevaCore", targets: ["Hireva"]),
        .executable(name: "Hireva", targets: ["HirevaRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs.git", exact: "4.1.0")
    ],
    targets: [
        .target(
            name: "Hireva",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "FSRS", package: "swift-fsrs")
            ],
            path: "Sources/Hireva",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "HirevaRunner",
            dependencies: [
                .target(name: "Hireva")
            ],
            path: "Sources/HirevaRunner"
        ),
        .testTarget(
            name: "HirevaTests",
            dependencies: [
                .target(name: "Hireva")
            ],
            path: "Tests/HirevaTests",
            resources: [
                .process("Fixtures/backend_candidate_profile.json"),
                .process("Fixtures/backend_opportunity_context.json"),
                .process("Fixtures/biomedical_candidate_profile.json"),
                .process("Fixtures/cybersecurity_candidate_profile.json"),
                .process("Fixtures/data_scientist_candidate_profile.json"),
                .process("Fixtures/product_manager_candidate_profile.json"),
                .process("Fixtures/release_64_questions.json"),
                .process("Fixtures/workflow_independent_102.json"),
                .process("Fixtures/DialogueScenarios/dialogue_scenarios_128.json"),
                .process("Fixtures/robotics_phd_candidate_profile.json"),
                .process("Fixtures/robotics_phd_opportunity_context.json"),
                .copy("Fixtures/WebSourcedSyntheticContexts")
            ]
        )
    ]
)
