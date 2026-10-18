// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Whorl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Whorl", targets: ["Whorl"]),
        .library(name: "WhorlCore", targets: ["WhorlCore"]),
    ],
    targets: [
        .target(name: "WhorlCore"),
        .executableTarget(name: "Whorl", dependencies: ["WhorlCore"]),
        .testTarget(name: "WhorlCoreTests", dependencies: ["WhorlCore"]),
    ]
)
