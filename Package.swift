// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tailbolt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tailbolt", targets: ["Tailbolt"]),
        .executable(name: "tailbolt-cli", targets: ["tailbolt-cli"]),
        .library(name: "TailboltCore", targets: ["TailboltCore"]),
    ],
    targets: [
        // Platform-neutral engine (Foundation + POSIX sockets) — meant to be reused on Linux/iOS later.
        .target(name: "TailboltCore"),
        .executableTarget(name: "Tailbolt", dependencies: ["TailboltCore"]),
        .executableTarget(name: "tailbolt-cli", dependencies: ["TailboltCore"]),
    ],
    swiftLanguageModes: [.v5]
)
