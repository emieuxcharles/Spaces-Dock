// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "SpacesDock", platforms: [.macOS("26.0")],
    products: [.executable(name: "SpacesDock", targets: ["SpacesDock"])],
    targets: [
        .target(name: "SpacesCore"),
        .target(name: "SpacesBridge", linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "SpacesDock", dependencies: ["SpacesCore", "SpacesBridge"]),
        .executableTarget(name: "CoreChecks", dependencies: ["SpacesCore"], path: "Tests/SpacesCoreTests")
    ], swiftLanguageModes: [.v5])
