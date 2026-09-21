#!/bin/bash
# Regression test for patch 0004 (ipstack: a failed device write must not end the stack). Needs no tunnel, device
# or network once the crates are cached — run scripts/build-tun2proxy-macos.sh first, which leaves the patched
# vendored crate at build/tun2proxy-macos/src/vendor/ipstack.
#
#   ./run.sh                 -> tests the patched vendored crate (expect: 2 passed)
#   ./run.sh /path/to/crate  -> tests another ipstack checkout, e.g. an unpatched one (expect the transient test to FAIL)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CRATE="${1:-$ROOT/build/tun2proxy-macos/src/vendor/ipstack}"
[ -f "$CRATE/src/lib.rs" ] || { echo "no ipstack crate at $CRATE" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ipstack-0004.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tests"
cp "$HERE/tests/flaky.rs" "$WORK/tests/"
sed "s#IPSTACK_PATH#$CRATE#" "$HERE/Cargo.toml.in" > "$WORK/Cargo.toml"
cd "$WORK"
cargo test --offline
