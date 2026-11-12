// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "HarborCore", targets: ["HarborCore"])],
    targets: [.target(name: "HarborCore"), .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"])],
    swiftLanguageModes: [.v6]
)
