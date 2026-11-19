// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MeetingAgent", path: "Sources/MeetingAgent")
    ]
)
