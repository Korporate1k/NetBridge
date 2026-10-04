# Shared by build-tun2proxy-apple.sh and build-tun2proxy-openwrt.sh: the ONE list of patches applied to tun2proxy
# and its vendored ipstack. Source it after defining PATCHES, REV and IPSTACK_VERSION.

# prepare_tree <dir> <with_0006b: 0|1> [<with_0009: 0|1>]: clone, patch and vendor one tun2proxy tree at <dir>/src.
# 0009 (portable-atomic instead of std AtomicU64) is only for targets without 64-bit atomics (32-bit MIPS), so the
# shipped Apple/Windows/aarch64 engines are built exactly as before.
prepare_tree() {
    local dir="$1" with_0006b="$2" with_0009="${3:-0}"
    rm -rf "$dir"
    mkdir -p "$dir"
    git clone -q https://github.com/tun2proxy/tun2proxy "$dir/src"
    (
        cd "$dir/src"
        git checkout -q "$REV"

        # tun2proxy itself.
        git apply "$PATCHES/0001-udp-no-connect-eisconn.patch"             # UDP relays: no EISCONN on Darwin
        git apply "$PATCHES/0003-virtual-dns-long-mapping-timeout.patch"   # virtual-DNS mappings live 24 h
        patch -s -p1 < "$PATCHES/0005-virtual-dns-nodata-for-non-a.patch"  # NODATA for AAAA and other non-A queries
        patch -s -p1 < "$PATCHES/0006a-engine-latency.patch"               # TCP_NODELAY, 5 s DNS sessions, 300 s TTL
        if [ "$with_0006b" = 1 ]; then
            patch -s -p1 < "$PATCHES/0006b-tcp-window-64k.patch"           # 64 KB TCP window (macOS only)
        fi
        patch -s -p1 < "$PATCHES/0007b-traffic-status-fastpath.patch"      # lock-free traffic_status_update
        patch -s -p1 < "$PATCHES/0008b-tun2proxy-tvos.patch"               # tvOS: same packet_information as iOS
        if [ "$with_0009" = 1 ]; then
            patch -s -p1 < "$PATCHES/0009-no-64bit-atomics.patch"          # 32-bit MIPS: no 64-bit atomics
        fi

        # The ipstack patches, so vendor the crate and redirect the dependency.
        cp "$PATCHES/tun2proxy-Cargo.lock" Cargo.lock
        # No --locked: the saved lock records ipstack as a path dependency, so cargo
        # rewrites that one entry here. Every other version stays pinned by the lock.
        cargo fetch >/dev/null
        mkdir -p vendor
        cp -R "$(ls -d "$HOME"/.cargo/registry/src/*/ipstack-$IPSTACK_VERSION | head -1)" vendor/ipstack
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0002-ipstack-upload-backpressure.patch")  # upload backpressure
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0004-ipstack-nonfatal-device-io.patch")   # failed device I/O not fatal
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0007a-ipstack-lazy-trace.patch")          # no eager per-packet log strings
        (cd vendor/ipstack && patch -s -p1 < "$PATCHES/0008a-ipstack-tvos.patch")                # tvOS: Darwin tun framing consts
        printf '\n[patch.crates-io]\nipstack = { path = "vendor/ipstack" }\n' >> Cargo.toml
    )
}
