// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Logiminus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "logiminus",
            path: "Sources/Logiminus",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "LogiminusTests",
            dependencies: ["logiminus"],
            path: "Tests/LogiminusTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
