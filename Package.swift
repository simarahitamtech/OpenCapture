// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OpenCapture",
    platforms: [
        .macOS(.v13)  // Requires macOS 13+ for best ScreenCaptureKit support
    ],
    products: [
        .executable(
            name: "OpenCapture",
            targets: ["OpenCapture"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenCapture",
            dependencies: [],
            path: "SimaraRecord/Sources",
            resources: [
                .copy("App/AppIcon.icns")
            ]
        )
    ]
)
