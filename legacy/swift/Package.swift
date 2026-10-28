// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "xclip",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XClipCore", targets: ["XClipCore"]),
        .executable(name: "xclip", targets: ["xclip"]),
        .executable(name: "XClipApp", targets: ["XClipApp"])
    ],
    targets: [
        .target(name: "XClipCore"),
        .executableTarget(
            name: "xclip",
            dependencies: ["XClipCore"]
        ),
        .executableTarget(
            name: "XClipApp",
            dependencies: ["XClipCore"],
            // SwiftUI VideoPlayer 只引用 _AVKit_SwiftUI 泛型符号，不会自动链接
            // AVKit.framework，运行时 getSuperclassMetadata 崩。显式链接双保险。
            // 见 KNOWN-ISSUES.md 第 3 节。
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(
            name: "XClipCoreTests",
            dependencies: ["XClipCore"]
        ),
        .testTarget(
            name: "XClipAppTests",
            dependencies: ["XClipApp"]
        )
    ]
)
