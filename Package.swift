// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KakaoTalkCLI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kakao", targets: ["KakaoTalkCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1"))
    ],
    targets: [
        .target(name: "KakaoCore"),
        .target(
            name: "KakaoMCP",
            dependencies: ["KakaoCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "KakaoTalkCLI",
            dependencies: [
                "KakaoCore",
                "KakaoMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "KakaoCoreTests", dependencies: ["KakaoCore"]),
        .testTarget(name: "KakaoMCPTests", dependencies: ["KakaoMCP", .product(name: "MCP", package: "swift-sdk")])
    ]
)