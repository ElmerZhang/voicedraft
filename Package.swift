// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDraft",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.executable(name: "VoiceDraft", targets: ["VoiceDraft"])],
    targets: [
        .target(name: "CVoiceDraft", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "VoiceDraftCore", dependencies: ["CVoiceDraft"], resources: [.process("Resources")]),
        .executableTarget(name: "VoiceDraft", dependencies: ["VoiceDraftCore"]),
        .testTarget(name: "VoiceDraftCoreTests", dependencies: ["VoiceDraftCore"]),
        .testTarget(name: "VoiceDraftTests", dependencies: ["VoiceDraft"])
    ]
)
