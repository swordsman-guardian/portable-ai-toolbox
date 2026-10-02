#!/usr/bin/env bash
# Portable AI toolbox entry point. Run from the USB root or invoke by path.
set -eu
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
unset NODE_OPTIONS NODE_PATH LD_PRELOAD LD_LIBRARY_PATH
ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ ! -f "$ROOT/scripts/ai.cjs" ]]; then echo "Toolbox files are incomplete: $ROOT/scripts/ai.cjs is missing." >&2; exit 1; fi
ARCHIVE="$ROOT/runtime/linux-x64/node-runtime.tar.xz"
MANIFEST="$ROOT/runtime/linux-x64/manifest.json"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then echo "The bundled Linux toolbox currently supports x86_64 Linux only." >&2; exit 126; fi
if [[ ! -f "$ARCHIVE" || ! -f "$MANIFEST" ]]; then echo "No verified portable Node archive found. Run: bash \"$ROOT/scripts/bootstrap-linux.sh\" \"$ROOT\"" >&2; exit 127; fi
# FAT32/noexec media cannot run its binaries. Verify the complete USB archive,
# then stage the bundled Node under a private, user-owned local cache.
EXPECTED="$(awk -F '\"' '$0 ~ /runtime\/linux-x64\/node-runtime\.tar\.xz/ {for (i=1; i<=NF; i++) if ($i == "runtime/linux-x64/node-runtime.tar.xz") {print $(i+2); exit}}' "$MANIFEST")"
PINNED_NODE_SHA='df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de'
if [[ "$EXPECTED" != "$PINNED_NODE_SHA" ]]; then echo "The manifest does not match the pinned official Node 22.23.3 archive." >&2; exit 1; fi
ACTUAL="$(/usr/bin/sha256sum "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL" != "$PINNED_NODE_SHA" ]]; then echo "Portable Node archive checksum mismatch." >&2; exit 1; fi
HOME_REAL="$(realpath -e -- "${HOME:?HOME is not set}")"
CACHE_BASE="$HOME_REAL/.cache"
umask 077
mkdir -p -- "$CACHE_BASE"
if [[ -L "$CACHE_BASE" || "$(stat -c '%u' "$CACHE_BASE")" != "$(id -u)" ]]; then echo "Private local cache must be a non-symlink directory owned by this user." >&2; exit 1; fi
CACHE="$CACHE_BASE/portable-ai-toolbox"
if [[ -e "$CACHE" && ( -L "$CACHE" || ! -d "$CACHE" || "$(stat -c '%u' "$CACHE")" != "$(id -u)" ) ]]; then echo "Portable runtime cache path is not a private user-owned directory." >&2; exit 1; fi
mkdir -p -- "$CACHE"; chmod 700 "$CACHE"
STAGE="$(mktemp -d "$CACHE/node.XXXXXXXX")"
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT INT TERM
if ! /usr/bin/tar -xJf "$ARCHIVE" -C "$STAGE" --strip-components=1 --no-same-owner --no-same-permissions; then exit 1; fi
if [[ ! -f "$STAGE/bin/node" || -L "$STAGE/bin/node" ]]; then echo "Verified archive did not contain a regular Node executable." >&2; exit 1; fi
chmod 700 "$STAGE/bin/node"
set +e
"$STAGE/bin/node" "$ROOT/scripts/ai.cjs" "$@"
RC=$?
set -e
exit "$RC"
