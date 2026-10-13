// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDraft",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VoiceDraft", targets: ["VoiceDraft"])],
    targets: [
        .target(name: "VoiceDraftCore", resources: [.process("Resources")]),
        .executableTarget(name: "VoiceDraft", dependencies: ["VoiceDraftCore"]),
        .testTarget(name: "VoiceDraftCoreTests", dependencies: ["VoiceDraftCore"])
    ]
)
