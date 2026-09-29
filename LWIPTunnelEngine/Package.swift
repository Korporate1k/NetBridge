// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LWIPTunnelEngine",
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(name: "LWIPTunnelEngine", targets: ["LWIPTunnelEngine"])
    ],
    targets: [
        // tun2proxy (Rust, ipstack-based tun2socks) as a static-library
        // xcframework, ios-arm64 + ios-arm64-simulator + macos-arm64 slices, all
        // three built by scripts/build-tun2proxy-apple.sh (since 2026-09-26; patches
        // 0001-0007b on every slice, except 0006b's 64 KB TCP window, macOS only
        // because of the iOS extension memory limit). Built from
        // github.com/tun2proxy/tun2proxy @ fc77ca3 (0.8.3) plus three local patches
        // (kept in LWIPTunnelEngine/patches/, applied in order): 0001 stops UDP
        // ASSOCIATE relays failing with EISCONN on Darwin, 0002 adds ipstack upload
        // backpressure, 0003 lengthens the virtual-DNS name mapping from 60 s to 24 h
        // (with an LRU cap) so a flow resuming after its session expired is not sent
        // to the raw fake 198.18.x.x address. See HANDOFF.md (2026-09-18, 2026-09-20).
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
        ),
        // Offline tests: they drive the packet framing over a plain socketpair and never start the engine or
        // touch the network, so `swift test` needs no tunnel, device or proxy. macOS only (the xcframework's
        // macos-arm64 slice is what links here).
        .testTarget(
            name: "LWIPTunnelEngineTests",
            dependencies: ["LWIPTunnelEngine"]
        )
    ]
)
