// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Managerie",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Managerie", targets: ["Managerie"]),
        .executable(name: "mnote", targets: ["mnote"]),
    ],
    dependencies: [
    ],
    targets: [
        // Main menubar app
        .executableTarget(
            name: "Managerie",
            dependencies: [],
            path: "Sources/Managerie",
            exclude: ["Info.plist", "Managerie.entitlements"],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources")
            ]
        ),
        // CLI tool
        .executableTarget(
            name: "mnote",
            path: "Sources/mnote"
        ),
        .testTarget(
            name: "ManagerieTests",
            dependencies: ["Managerie"],
            path: "Tests/ManagerieTests"
        )
    ]
)
