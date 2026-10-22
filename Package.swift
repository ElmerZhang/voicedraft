// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDraft",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .executable(name: "VoiceDraft", targets: ["VoiceDraft"]),
        // Linked by the iOS app target in ios/VoiceDraft.xcodeproj.
        .library(name: "VoiceDraftCore", targets: ["VoiceDraftCore"])
    ],
    targets: [
        .target(name: "CVoiceDraft", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "VoiceDraftCore", dependencies: ["CVoiceDraft"], resources: [.process("Resources")]),
        .executableTarget(name: "VoiceDraft", dependencies: ["VoiceDraftCore"]),
        .testTarget(name: "VoiceDraftCoreTests", dependencies: ["VoiceDraftCore"]),
        .testTarget(name: "VoiceDraftTests", dependencies: ["VoiceDraft"])
    ]
)
