// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PremiumInsightTraining",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PremiumInsightTrainer", targets: ["PremiumInsightTrainer"])
    ],
    targets: [
        .executableTarget(name: "PremiumInsightTrainer")
    ]
)
