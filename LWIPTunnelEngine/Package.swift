// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LWIPTunnelEngine",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "LWIPTunnelEngine", targets: ["LWIPTunnelEngine"])
    ],
    targets: [
        // tun2proxy (Rust, ipstack-based tun2socks) as a static-library
        // xcframework, ios-arm64 + ios-arm64-simulator slices. Built from
        // github.com/tun2proxy/tun2proxy @ fc77ca3 (0.8.3) plus a local patch
        // that stops UDP ASSOCIATE relays failing with EISCONN on Darwin — see
        // ~/Desktop/tun2proxy-test/patches/ and HANDOFF.md (2026-09-18).
        //
        // This replaced the vendored BadVPN tun2socks (`Sources/CTun2Socks`,
        // left on disk but no longer built): tun2proxy speaks standard SOCKS5
        // UDP ASSOCIATE (BadVPN needed a udpgw server) and handles IPv6.
        .binaryTarget(
            name: "tun2proxy",
            path: "tun2proxy.xcframework"
        ),
        .target(
            name: "LWIPTunnelEngine",
            dependencies: ["tun2proxy"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
