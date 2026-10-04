#!/bin/bash
# NetBridge router setup: one command for any supported OpenWrt router (GL.iNet GL-MT3000 / GL-MT6000 and other aarch64,
# GL-SFT1200 and other little-endian 32-bit MIPS, x86-64). From this Mac it:
#   1. connects to the router once over SSH (one password prompt at most, the connection is reused)
#   2. detects the CPU and firmware, and checks the router has what NetBridge needs (OpenWrt, the tun driver, space)
#   3. builds the matching package if it is missing or older than the sources (or uses --package)
#   4. installs it (install.sh: architecture + run check first, your existing settings kept)
#   5. asks for the phone's address (suggested from the router's default route), port, username, password and policy
#   6. starts NetBridge and waits until the proxy answers, explaining what is wrong if it doesn't
#
#   NetBridgeOpenWrt/setup-router.sh [ROUTER_IP] [options]          (router defaults to 192.168.8.1, user root)
#     --phone IP   --port N   --user NAME   --policy block|fallback   settings (otherwise asked; current ones offered)
#     --package FILE   use this package instead of building      --rebuild   always rebuild the package
#     --yes        don't ask: take the defaults (password from $NB_PASS, or keep the saved one)
#     --uninstall  stop NetBridge, restore DNS/firewall, remove its files (and, unless you say no, its settings)
#   The password is read without echo (or from $NB_PASS) and sent over the SSH connection's input, never as a command
#   argument and never into your shell history. $NB_SSH_EXTRA adds ssh options (e.g. "-i ~/.ssh/key -p 2222").
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"   # BASH_SOURCE: right when sourced too

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- pure helpers (unit tests: test-rig/setup-router-unit.sh; end-to-end: test-rig/setup-router-test.sh) -----------
# router CPU (uname -m) + ELF byte order of its own busybox (01 little, 02 big) -> Rust target of our package
target_for() {
    case "$1:$2" in
        aarch64:*|arm64:*) echo aarch64-unknown-linux-musl ;;
        x86_64:*)          echo x86_64-unknown-linux-musl ;;
        mips:01|mipsel:01) echo mipsel-unknown-linux-musl ;;
        *) return 1 ;;
    esac
}
valid_ip4() {
    case "$1" in ""|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    local IFS=. o; set -- $1; [ $# -eq 4 ] || return 1
    for o; do [ "$o" -le 255 ] 2>/dev/null || return 1; done
}
valid_port() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
# single-quote a value for the router's shell
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# space the package needs once installed, in KB (MIPS engines are bigger: std is built from source)
need_kb() { case "$1" in mipsel-*) echo 12000 ;; *) echo 9000 ;; esac; }

# --- interaction --------------------------------------------------------------------------------------------------
ask() {  # ask VAR "question" default
    local var="$1" q="$2" def="${3:-}" ans=""
    if [ "$YES" = 1 ]; then ans="$def"
    else read -r -p "$q${def:+ [$def]}: " ans </dev/tty || true; [ -n "$ans" ] || ans="$def"; fi
    printf -v "$var" '%s' "$ans"
}
confirm() {  # confirm "question" (default yes)
    [ "$YES" = 1 ] && return 0
    local a; read -r -p "$1 [Y/n]: " a </dev/tty || true
    case "$a" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

r() { ssh $NB_SSH_OPTS "root@$ROUTER" "$@"; }

uninstall() {
    step "Removing NetBridge from $ROUTER"
    local wipe=0; confirm "Also delete NetBridge's saved settings on the router (server, username, password)?" && wipe=1
    r 'sh -s' <<REMOTE
if [ -x /etc/init.d/netbridge ]; then /etc/init.d/netbridge stop; /etc/init.d/netbridge disable; fi   # stop restores DNS + firewall
[ -x /etc/init.d/netbridge-guard ] && /etc/init.d/netbridge-guard disable
rm -f /etc/init.d/netbridge /etc/init.d/netbridge-guard /usr/bin/netbridge /usr/bin/nb-probe /usr/bin/tun2proxy-bin
rm -rf /usr/libexec/netbridge /var/run/netbridge
[ "$wipe" = 1 ] && rm -f /etc/config/netbridge
echo removed
REMOTE
    say "NetBridge removed.$([ "$wipe" = 1 ] && echo ' Its settings were deleted.' || echo ' Its settings were kept in /etc/config/netbridge.')"
}

main() {
    ROUTER=192.168.8.1; PHONE=""; PORT=""; USERNAME=""; POLICY=""; PKG=""; REBUILD=0; YES=0; UNINSTALL=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --phone)   PHONE="${2:?--phone needs an IP}"; shift 2 ;;
            --port)    PORT="${2:?--port needs a number}"; shift 2 ;;
            --user)    USERNAME="${2-}"; shift 2 ;;
            --policy)  POLICY="${2:?--policy needs block or fallback}"; shift 2 ;;
            --package) PKG="${2:?--package needs a file}"; shift 2 ;;
            --rebuild) REBUILD=1; shift ;;
            --yes|-y)  YES=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            -h|--help) usage 0 ;;
            -*) say "unknown option: $1"; usage 2 ;;
            *)  ROUTER="$1"; shift ;;
        esac
    done

    # one SSH connection for everything, so the router password (if it uses one) is asked once
    CM_DIR=$(mktemp -d)
    NB_SSH_OPTS="-o ControlMaster=auto -o ControlPath=$CM_DIR/cm -o ControlPersist=300 -o ConnectTimeout=10 ${NB_SSH_EXTRA:-}"
    export NB_SSH_OPTS
    trap 'ssh -o ControlPath="$CM_DIR/cm" -O exit "root@$ROUTER" >/dev/null 2>&1 || true; rm -rf "$CM_DIR"' EXIT

    step "Connecting to root@$ROUTER"
    r true || die "can't SSH to root@$ROUTER (is this the router's address, and is SSH on? GL.iNet: same password as the web UI)"

    [ "$UNINSTALL" = 1 ] && { uninstall; return 0; }

    step "Checking the router"
    facts=$(r 'sh -s' <<'REMOTE'
echo "machine=$(uname -m)"
echo "endian=$(od -An -tx1 -j5 -N1 /bin/busybox 2>/dev/null | tr -d ' \n')"
if [ -f /etc/openwrt_release ]; then . /etc/openwrt_release; echo "release=${DISTRIB_DESCRIPTION:-OpenWrt}"; else echo "release="; fi
[ -c /dev/net/tun ] && echo tun=yes || echo tun=no
free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ -n "$free" ] || free=$(df -k / | awk 'NR==2{print $4}')
echo "free_kb=$free"
echo "gateway=$(ip route show default 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -n 1)"
echo "gwdev=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
[ -x /etc/init.d/netbridge ] && echo installed=yes || echo installed=no
command -v opkg >/dev/null && echo opkg=yes || echo opkg=no
for k in server_host server_port username policy; do echo "cur_$k=$(uci -q get netbridge.main.$k)"; done
[ -n "$(uci -q get netbridge.main.password)" ] && echo cur_haspass=yes || echo cur_haspass=no
REMOTE
)
    get() { printf '%s\n' "$facts" | sed -n "s/^$1=//p"; }
    [ -n "$(get release)" ] || die "this doesn't look like OpenWrt (no /etc/openwrt_release)"
    TARGET=$(target_for "$(get machine)" "$(get endian)") || die "unsupported CPU: $(get machine) (byte order $(get endian)); supported: aarch64, little-endian 32-bit MIPS, x86-64"
    ARCH="${TARGET%%-*}"
    say "Firmware: $(get release)"
    say "CPU: $(get machine) -> package $ARCH"
    say "Internet via: $(get gwdev) (gateway $(get gateway))"

    if [ "$(get tun)" != yes ]; then
        [ "$(get opkg)" = yes ] || die "the router has no tun driver (/dev/net/tun) and no opkg to install kmod-tun"
        confirm "The router has no tun driver. Install kmod-tun now (needs internet on the router)?" || die "kmod-tun is required"
        r 'opkg update >/dev/null && opkg install kmod-tun && { [ -c /dev/net/tun ] || modprobe tun; } && [ -c /dev/net/tun ]' \
            || die "installing kmod-tun failed"
        say "kmod-tun installed"
    fi
    if [ "$(get installed)" != yes ] && [ "$(get free_kb)" -lt "$(need_kb "$TARGET")" ] 2>/dev/null; then
        die "not enough space on the router: $(get free_kb) KB free, about $(need_kb "$TARGET") KB needed"
    fi

    step "Package"
    if [ -n "$PKG" ]; then
        [ -f "$PKG" ] || die "package not found: $PKG"
        say "Using $PKG"
    else
        PKG="$ROOT/build/netbridge-openwrt-$ARCH.tar.gz"
        local engine_src="$ROOT/LWIPTunnelEngine/patches $ROOT/scripts/lib $ROOT/scripts/build-tun2proxy-openwrt.sh $HERE/nb-probe/src"
        local pkg_src="$HERE/files $ROOT/scripts/build-openwrt-package.sh"
        local skip=1
        if [ "$REBUILD" = 1 ] || [ ! -f "$PKG" ] || [ -n "$(find $engine_src -type f -newer "$PKG" 2>/dev/null | head -n 1)" ]; then skip=0; fi
        if [ "$skip" = 1 ] && [ -z "$(find $pkg_src -type f -newer "$PKG" 2>/dev/null | head -n 1)" ]; then
            say "Up to date: $PKG"
        else
            if [ "$skip" = 1 ]; then say "Repackaging (scripts changed, engine unchanged)..."
            else say "Building the $ARCH engine and package (this takes a few minutes)..."; fi
            TARGET="$TARGET" SKIP_BUILD="$skip" "$ROOT/scripts/build-openwrt-package.sh" >"$CM_DIR/build.log" 2>&1 \
                || { tail -20 "$CM_DIR/build.log"; die "building the package failed"; }
            say "Built $PKG"
        fi
    fi

    step "Installing"
    NB_QUIET_NEXT=1 "$HERE/install.sh" "$ROUTER" "$PKG"

    step "Settings"
    local gw; gw=$(get gateway)
    ask PHONE "Phone address (the iPhone's IP as the router sees it; with USB tethering, the gateway)" "${PHONE:-$(get cur_server_host)}"
    [ -n "$PHONE" ] || ask PHONE "Phone address" "$gw"
    valid_ip4 "$PHONE" || die "'$PHONE' is not an IPv4 address"
    ask PORT "Proxy port (shown in the NetBridge app)" "${PORT:-$(get cur_server_port)}"
    [ -n "$PORT" ] || ask PORT "Proxy port" 8081
    valid_port "$PORT" || die "'$PORT' is not a port number"
    ask USERNAME "Proxy username (empty for none)" "${USERNAME:-$(get cur_username)}"
    local passcmd=""
    if [ -n "$USERNAME" ]; then
        local pass="${NB_PASS:-}"
        if [ -z "$pass" ] && [ "$YES" != 1 ]; then
            local hint=""; [ "$(get cur_haspass)" = yes ] && hint=" (Enter keeps the saved one)"
            read -r -s -p "Proxy password$hint: " pass </dev/tty || true; echo
        fi
        if [ -n "$pass" ]; then passcmd="uci set netbridge.main.password=$(sq "$pass")"
        elif [ "$(get cur_haspass)" != yes ]; then die "a password is needed for user '$USERNAME' (or set NB_PASS)"; fi
    else
        passcmd="uci -q delete netbridge.main.password"
    fi
    ask POLICY "If the proxy stops answering: block (nothing goes around it) or fallback (plain tethering)" "${POLICY:-$(get cur_policy)}"
    [ -n "$POLICY" ] || POLICY=block
    case "$POLICY" in block|fallback) ;; *) die "policy must be block or fallback" ;; esac

    step "Starting NetBridge"
    # everything goes over the SSH connection's input: the password never appears in a command line here
    r 'sh -s' <<REMOTE
uci set netbridge.main.server_host=$(sq "$PHONE")
uci set netbridge.main.server_port=$(sq "$PORT")
uci set netbridge.main.username=$(sq "$USERNAME")
$passcmd
uci set netbridge.main.policy=$(sq "$POLICY")
uci set netbridge.main.enabled=1
uci commit netbridge
/etc/init.d/netbridge enable
/etc/init.d/netbridge-guard enable
rm -f /var/run/netbridge/status   # so the wait below only ever sees the NEW watchdog's verdict, not the last run's
/etc/init.d/netbridge restart
REMOTE
    local state="" status=""
    for _ in $(seq 1 45); do
        status=$(r '/usr/libexec/netbridge/ctl status' 2>/dev/null || true)
        state=$(printf '%s\n' "$status" | sed -n 's/^state=//p')
        case "$state" in healthy|auth_rejected|down) break ;; esac
        sleep 1
    done
    local udp detail; udp=$(printf '%s\n' "$status" | sed -n 's/^udp=//p'); detail=$(printf '%s\n' "$status" | sed -n 's/^detail=//p')
    case "$state" in
        healthy)
            say "NetBridge is running on $ROUTER: the proxy at $PHONE:$PORT answers (UDP relayed: $udp), policy $POLICY."
            say "Check from a device on the router's Wi-Fi: browse the web; its public IP should be your phone carrier's."
            say "On the router: 'netbridge status', 'netbridge log'. To remove: $0 $ROUTER --uninstall" ;;
        auth_rejected)
            die "the phone's proxy refused the username/password ($detail). Re-run and enter the ones set in the NetBridge app." ;;
        *)
            r 'tail -n 5 /var/run/netbridge/log 2>/dev/null' || true
            local what="the LAN uses plain tethering until it answers"
            [ "$POLICY" = block ] && what="the LAN stays blocked until it answers"
            die "no SOCKS5 answer from $PHONE:$PORT ($detail). Is the NetBridge app open in the foreground with its proxy running, the phone tethered, and the port right? Policy $POLICY: $what."
            ;;
    esac
}

[ "${NB_SETUP_LIB:-0}" = 1 ] || main "$@"
