// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WebinarNihongo",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "WebinarNihongo", targets: ["WebinarNihongo"])],
    targets: [
        .target(name: "WebinarCore"),
        .executableTarget(name: "SpeechBufferChecks", dependencies: ["WebinarCore"], path: "Tests/SpeechBufferChecks"),
        .executableTarget(name: "WebinarProbe"),
        .executableTarget(name: "WebinarNihongo", dependencies: ["WebinarCore"]),
        .executableTarget(name: "WebinarCoreChecks", dependencies: ["WebinarCore"], path: "Tests/WebinarCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
