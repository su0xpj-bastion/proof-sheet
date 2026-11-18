// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "proof-sheet",
    platforms: [.macOS(.v11), .iOS(.v14)],
    products: [.library(name: "ProofKit", targets: ["ProofKit"])],
    targets: [
        .target(name: "ProofKit"),
        .target(name: "ProofChecks", dependencies: ["ProofKit"]),
        .executableTarget(name: "ps", dependencies: ["ProofKit", "ProofChecks"]),
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit", "ProofChecks"]),
    ]
)
