// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Socks5Client",
    platforms: [
        .iOS(.v15),
        .tvOS(.v17),
        // macOS target exists purely so `swift test` runs headlessly here —
        // no simulator/device needed to exercise the loopback mock server.
        .macOS(.v12)
    ],
    products: [
        .library(name: "Socks5Client", targets: ["Socks5Client"])
    ],
    targets: [
        .target(name: "Socks5Client"),
        .testTarget(name: "Socks5ClientTests", dependencies: ["Socks5Client"])
    ]
)
