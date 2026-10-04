#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset NODE_OPTIONS NODE_PATH LD_PRELOAD LD_LIBRARY_PATH

# Download and package verified Linux x64 runtime assets for the portable USB
# tree. This script uses the host's existing tools only; it never installs an
# operating-system package or writes into the host's standard configuration.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then echo 'Run as a regular user; root is not needed.' >&2; exit 2; fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then echo 'Supported bootstrap target is Linux x86_64.' >&2; exit 2; fi
if [[ ! -r /etc/os-release ]]; then echo 'Unsupported packaging host: use Ubuntu 24.04 x86_64 to build the Linux runtime.' >&2; exit 2; fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then echo 'Unsupported packaging host: use Ubuntu 24.04 x86_64 to build the Linux runtime.' >&2; exit 2; fi
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
GUARD_PID=
cleanup() {
  if [[ -n ${GUARD_PID:-} ]]; then
    kill -TERM "$GUARD_PID" 2>/dev/null || true
    wait "$GUARD_PID" 2>/dev/null || true
    GUARD_PID=
  fi
  if [[ -e $WORK/.apparmor-cleanup-unconfirmed || -L $WORK/.apparmor-cleanup-unconfirmed ]]; then
    echo "AppArmor cleanup could not be confirmed; retained private bootstrap workspace for recovery: $WORK" >&2
    return
  fi
  rm -rf -- "$WORK"
}
handle_guard_signal() {
  local signal=$1 status=143
  case $signal in INT) status=130 ;; HUP) status=129 ;; esac
  trap '' INT TERM HUP
  if [[ -n ${GUARD_PID:-} ]]; then
    kill -s "$signal" "$GUARD_PID" 2>/dev/null || true
    wait "$GUARD_PID" 2>/dev/null || true
    GUARD_PID=
  fi
  exit "$status"
}
MODE=prepare
if (($# == 3)) && [[ $1 == --continue ]]; then
  MODE=continue
  ROOT_ARG=$2
  WORK_ARG=$3
elif (($# == 1)); then
  ROOT_ARG=$1
else
  echo 'Usage: bootstrap-linux.sh /path/to/portable-root' >&2
  exit 2
fi
ROOT=$(realpath -e -- "$ROOT_ARG")
[[ -d $ROOT ]] || { echo 'Portable root must be an existing directory.' >&2; exit 2; }
for c in curl tar apt-get dpkg-deb ldd; do command -v "$c" >/dev/null || { echo "Missing host bootstrap utility: $c" >&2; exit 2; }; done
if [[ $MODE == prepare ]]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/aistick-linux-bootstrap.XXXXXXXX")
  chmod 700 -- "$WORK"
  trap cleanup EXIT
  trap 'handle_guard_signal INT' INT
  trap 'handle_guard_signal TERM' TERM
  trap 'handle_guard_signal HUP' HUP
else
  WORK=$WORK_ARG
  [[ -d $WORK && $(realpath -e -- "$WORK") == "$WORK" ]] || { echo 'Rejected continuation: WORK must be an existing canonical directory.' >&2; exit 2; }
  [[ $(basename -- "$WORK") == aistick-linux-bootstrap.* ]] || { echo 'Rejected continuation: WORK path is not an owned bootstrap workspace.' >&2; exit 2; }
  [[ $(stat -c '%u:%a' -- "$WORK") == "$(id -u):700" ]] || { echo 'Rejected continuation: WORK must be owned by the current user with mode 0700.' >&2; exit 2; }
  [[ ${AISTICK_USERNS_GUARD_PID:-} =~ ^[1-9][0-9]*$ && ${AISTICK_USERNS_GUARD_PID} == "$PPID" && -r /proc/$PPID/cmdline ]] || { echo 'Rejected continuation: bootstrap must be handed off by the live AppArmor userns guard.' >&2; exit 2; }
  local_guard_cmd=()
  mapfile -d '' -t local_guard_cmd < "/proc/$PPID/cmdline"
  expected_runtime_json=$(printf '{"sessionRoot":"%s","runtimeRoot":"%s","sandboxRoot":"%s","bwrap":"%s"}' "$WORK" "$WORK" "$WORK/bwrap" "$WORK/bwrap/root/usr/bin/bwrap")
  [[ ${#local_guard_cmd[@]} -eq 10 \
    && ${local_guard_cmd[0]} == "$WORK/node/bin/node" \
    && ${local_guard_cmd[0]} == "$(readlink -f -- "/proc/$PPID/exe")" \
    && ${local_guard_cmd[1]} == "$SCRIPT_DIR/linux-userns.cjs" \
    && ${local_guard_cmd[2]} == --guard-command \
    && ${local_guard_cmd[3]} == "$expected_runtime_json" \
    && ${local_guard_cmd[4]} == -- \
    && ${local_guard_cmd[5]} == bash \
    && ${local_guard_cmd[6]} == "$SCRIPT_DIR/bootstrap-linux.sh" \
    && ${local_guard_cmd[7]} == --continue \
    && ${local_guard_cmd[8]} == "$ROOT" \
    && ${local_guard_cmd[9]} == "$WORK" ]] || { echo 'Rejected continuation: live guard command line does not match this bootstrap workspace.' >&2; exit 2; }
  [[ -x $WORK/node/bin/node && -x $WORK/bwrap/root/usr/bin/bwrap && -f $WORK/bwrap-runtime-ready ]] || { echo 'Rejected continuation: verified Node and bubblewrap preparation is incomplete.' >&2; exit 2; }
fi
mkdir -p "$WORK/download-home"
safe_curl() { env -i PATH="$PATH" HOME="$WORK/download-home" /usr/bin/curl "$@"; }
RT="$ROOT/runtime/linux-x64"; TOOLS="$ROOT/tools/linux-x64"; NPM="$ROOT/npm-global/linux-x64"
NODE_VER=22.23.3
UV_VER=0.8.22
CC_VER=3.20.4
NODE_FILE="node-v${NODE_VER}-linux-x64.tar.xz"
download_ranges() {
  local url=$1 output=$2 total=$3 chunk=4194304 start end index part size failed=0
  local parts="$WORK/ranges-$(basename "$output")"
  mkdir -p "$parts"
  local -a jobs=()
  index=0
  for ((start=0; start<total; start+=chunk)); do
    end=$((start+chunk-1)); ((end>=total)) && end=$((total-1))
    part=$(printf '%s/%05d' "$parts" "$index")
    env -i PATH="$PATH" HOME="$WORK/download-home" /usr/bin/curl --fail --location --silent --show-error --retry 4 --retry-all-errors --connect-timeout 20 --max-time 240 \
      --range "${start}-${end}" "$url" -o "$part" &
    jobs+=("$!")
    if ((${#jobs[@]} == 4)); then
      for job in "${jobs[@]}"; do wait "$job" || failed=1; done
      jobs=()
      if ((failed)); then
        rm -rf -- "$parts"
        return 1
      fi
    fi
    index=$((index+1))
  done
  for job in "${jobs[@]}"; do wait "$job" || failed=1; done
  jobs=()
  if ((failed)); then
    rm -rf -- "$parts"
    return 1
  fi
  : > "$output"
  for ((index=0,start=0; start<total; index++,start+=chunk)); do
    part=$(printf '%s/%05d' "$parts" "$index")
    size=$(stat -c '%s' "$part")
    end=$((start+chunk)); ((end>total)) && end=$total
      [[ $size -eq $((end-start)) ]] || { echo "Range size mismatch for $url" >&2; rm -rf -- "$parts"; rm -f -- "$output"; return 1; }
    cat -- "$part" >> "$output"
  done
  [[ $(stat -c '%s' "$output") -eq $total ]] || { echo "Downloaded size mismatch for $url" >&2; rm -rf -- "$parts"; rm -f -- "$output"; return 1; }
  rm -rf -- "$parts"
}
download_full_verified() {
  local url=$1 output=$2 total=$3 sha=$4 timeout=$5 full="$2.full-download"
  rm -f -- "$full"
  if safe_curl --fail --location --silent --show-error --retry 1 --retry-all-errors --connect-timeout 15 --max-time "$timeout" "$url" -o "$full" \
    && [[ $(stat -c '%s' -- "$full") -eq $total ]] \
    && echo "$sha  $full" | sha256sum --check --status; then
    mv -f -- "$full" "$output"
    return 0
  fi
  rm -f -- "$full"
  return 1
}
download_verified_asset() {
  local primary_url=$1 fallback_url=$2 output=$3 total=$4 sha=$5 primary_timeout=${6:-300} fallback_timeout=${7:-300} range_url=${8:-}
  if download_full_verified "$primary_url" "$output" "$total" "$sha" "$primary_timeout"; then return 0; fi
  if download_full_verified "$fallback_url" "$output" "$total" "$sha" "$fallback_timeout"; then return 0; fi
  rm -f -- "$output"
  if [[ -n $range_url ]]; then
    if ! download_ranges "$range_url" "$output" "$total"; then
      echo "Could not download verified release asset from primary or fallback sources." >&2
      return 1
    fi
    if ! echo "$sha  $output" | sha256sum --check --status; then
      echo "Release asset checksum mismatch: $range_url" >&2
      rm -f -- "$output"
      return 1
    fi
    return 0
  fi
  echo 'Could not download a verified release asset from the primary or fallback source.' >&2
  return 1
}
if [[ $MODE == prepare ]]; then
# This pin was copied from Node.js v22.23.3's official SHASUMS256.txt entry
# for node-v22.23.3-linux-x64.tar.xz and verified against the downloaded archive.
NODE_SHA=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
NODE_SIZE=31001304
if [[ -f $RT/node-runtime.tar.xz && $(stat -c '%s' -- "$RT/node-runtime.tar.xz") -eq $NODE_SIZE ]] \
  && echo "$NODE_SHA  $RT/node-runtime.tar.xz" | sha256sum --check --status; then
  cp -- "$RT/node-runtime.tar.xz" "$WORK/$NODE_FILE"
else
  download_verified_asset \
    "https://nodejs.org/dist/v${NODE_VER}/${NODE_FILE}" \
    "https://registry.npmmirror.com/-/binary/node/v${NODE_VER}/${NODE_FILE}" \
    "$WORK/$NODE_FILE" "$NODE_SIZE" "$NODE_SHA" 300 300
fi
mkdir -p "$WORK/node"
tar -xJf "$WORK/$NODE_FILE" -C "$WORK/node" --strip-components=1
NODE="$WORK/node/bin/node"; NPM_CLI="$WORK/node/lib/node_modules/npm/bin/npm-cli.js"

UV_SHA=741ff1f5742c5a4a25d2f829e8395355e43f7a5ae2ebc6368e9ae2df0efb69cf
UV_SIZE=21291955
if [[ -f $RT/uv-runtime.tar.gz ]] && echo "$UV_SHA  $RT/uv-runtime.tar.gz" | sha256sum --check --status; then
  cp -- "$RT/uv-runtime.tar.gz" "$WORK/uv.tar.gz"
else
  download_verified_asset \
    "https://releases.astral.sh/github/uv/releases/download/${UV_VER}/uv-x86_64-unknown-linux-gnu.tar.gz" \
    "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-x86_64-unknown-linux-gnu.tar.gz" \
    "$WORK/uv.tar.gz" "$UV_SIZE" "$UV_SHA" 300 300 \
    "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-x86_64-unknown-linux-gnu.tar.gz"
fi

CC_URL="https://github.com/farion1231/cc-switch/releases/download/v${CC_VER}/CC-Switch-v${CC_VER}-Linux-x86_64.AppImage"
CC_SHA=c8d66d8193fd00fd12239bd06a8c50f517badbf50d9020a4662e95e907b318ef
if [[ -f $RT/cc-switch.AppImage ]] && echo "$CC_SHA  $RT/cc-switch.AppImage" | sha256sum --check --status; then
  echo 'Using the already verified official CC Switch AppImage.'
  cp -- "$RT/cc-switch.AppImage" "$WORK/cc-switch.AppImage"
else
  download_verified_asset "$CC_URL" "https://gh-proxy.com/${CC_URL}" "$WORK/cc-switch.AppImage" 93010424 "$CC_SHA" 120 300
fi

# Retrieve Ubuntu's published bubblewrap package without installing it. Package
# files and their runtime shared libraries are retained in a tar archive.
mkdir -p "$WORK/bwrap/debs" "$WORK/bwrap/root"
(cd "$WORK/bwrap/debs" && apt-get download bubblewrap >/dev/null)
DEB=$(find "$WORK/bwrap/debs" -maxdepth 1 -name 'bubblewrap_*.deb' -print -quit)
[[ -n $DEB ]] || { echo 'Could not download the Ubuntu bubblewrap package.' >&2; exit 1; }
dpkg-deb -x "$DEB" "$WORK/bwrap/root"
BW="$WORK/bwrap/root/usr/bin/bwrap"
[[ -x $BW ]] || { echo 'Downloaded bubblewrap package did not contain its executable.' >&2; exit 1; }
mkdir -p "$WORK/bwrap/root/lib" "$WORK/bwrap/root/lib64"
while read -r lib; do
  [[ $lib = /* && -e $lib ]] || continue
  cp -L --parents -- "$lib" "$WORK/bwrap/root"
done < <(ldd "$BW" | sed -nE 's/.*=> ([^ ]+) .*/\1/p; s/^\s*(\/[^ ]+) .*/\1/p')
tar -C "$WORK/bwrap/root" -czf "$WORK/bwrap-runtime.tar.gz" .
touch "$WORK/bwrap-runtime-ready"

# Keep the archive layout stable, while placing private copies of the staged
# loader directories where sandboxExecEnv expects them for the host-side
# bubblewrap executable.
mkdir -p "$WORK/bwrap/sandbox/lib"
for loader_dir in "$WORK/bwrap/root/lib/x86_64-linux-gnu" "$WORK/bwrap/root/lib64"; do
  [[ -d $loader_dir && ! -L $loader_dir ]] || continue
  rel=${loader_dir#"$WORK/bwrap/root/"}
  mkdir -p "$WORK/bwrap/sandbox/$(dirname -- "$rel")"
  cp -a -- "$loader_dir" "$WORK/bwrap/sandbox/$(dirname -- "$rel")/"
done
fi

if [[ $MODE == prepare ]]; then
  # The guard keeps the exact approved profile loaded until the continuation
  # exits. The parent owns WORK and removes it only after guard teardown.
  RUNTIME_JSON=$("$WORK/node/bin/node" -e 'process.stdout.write(JSON.stringify({sessionRoot:process.argv[1],runtimeRoot:process.argv[1],sandboxRoot:process.argv[2],bwrap:process.argv[3]}))' "$WORK" "$WORK/bwrap" "$WORK/bwrap/root/usr/bin/bwrap")
  {
    "$WORK/node/bin/node" "$SCRIPT_DIR/linux-userns.cjs" --guard-command "$RUNTIME_JSON" -- bash "$SCRIPT_DIR/bootstrap-linux.sh" --continue "$ROOT" "$WORK" <&0 &
    GUARD_PID=$!
  }
  set +e
  wait "$GUARD_PID"
  GUARD_STATUS=$?
  set -e
  GUARD_PID=
  if ((GUARD_STATUS != 0)); then
    echo "AppArmor/user namespace authorization or guarded bootstrap continuation failed (status $GUARD_STATUS); preparation stopped." >&2
  fi
  exit "$GUARD_STATUS"
fi

if [[ $MODE == continue ]]; then
  mkdir -p -- "$RT" "$TOOLS" "$NPM"
  cp -- "$WORK/$NODE_FILE" "$RT/node-runtime.tar.xz"
  cp -- "$WORK/uv.tar.gz" "$RT/uv-runtime.tar.gz"
  cp -- "$WORK/cc-switch.AppImage" "$RT/cc-switch.AppImage"
  cp -- "$WORK/bwrap-runtime.tar.gz" "$RT/bwrap-runtime.tar.gz"
fi

NODE="$WORK/node/bin/node"
NPM_CLI="$WORK/node/lib/node_modules/npm/bin/npm-cli.js"
BW="$WORK/bwrap/root/usr/bin/bwrap"
BWRAP_LD_LIBRARY_PATH=$("$NODE" -e 'const {sandboxExecEnv}=require(process.argv[1]);process.stdout.write(sandboxExecEnv(process.argv[2],process.argv[3]).LD_LIBRARY_PATH||"")' "$SCRIPT_DIR/linux-sandbox.cjs" "$WORK" "$WORK/bwrap")
bwrap_exec() {
  if [[ -n $BWRAP_LD_LIBRARY_PATH ]]; then
    env LD_LIBRARY_PATH="$BWRAP_LD_LIBRARY_PATH" "$BW" "$@"
  else
    "$BW" "$@"
  fi
}

# Run npm's lifecycle scripts under the same user/PID/IPC/UTS namespace model
# used by sessions. Network remains available only for this explicit package
# fetch; HOME and writable paths are temporary bootstrap directories.
mkdir -p "$WORK/bootstrap-etc"
printf 'root:x:0:0:Portable Bootstrap:/home/bootstrap:/bin/sh\n' > "$WORK/bootstrap-etc/passwd"
printf 'root:x:0:\n' > "$WORK/bootstrap-etc/group"
printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\nnetworks: files\nprotocols: files\nservices: files\n' > "$WORK/bootstrap-etc/nsswitch.conf"
printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' > "$WORK/bootstrap-etc/hosts"
awk '$1 == "nameserver" && $2 ~ /^[0-9A-Fa-f:.]+$/ {print "nameserver " $2}' /etc/resolv.conf > "$WORK/bootstrap-etc/resolv.conf"
[[ -s $WORK/bootstrap-etc/resolv.conf ]] || printf 'nameserver 1.1.1.1\n' > "$WORK/bootstrap-etc/resolv.conf"
printf 'options timeout:2 attempts:2\n' >> "$WORK/bootstrap-etc/resolv.conf"
printf 'NAME="Portable Linux Bootstrap"\nID=portable\nPRETTY_NAME="Portable Linux Bootstrap"\n' > "$WORK/bootstrap-etc/os-release"
: > "$WORK/bootstrap-etc/npm-user.npmrc"
: > "$WORK/bootstrap-etc/npm-global.npmrc"
run_bubblewrap() {
  bwrap_exec --clearenv --die-with-parent --new-session --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
    --uid 0 --gid 0 --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin \
    --ro-bind /lib /lib --ro-bind /lib64 /lib64 --dir /etc --dir /etc/ssl --dir /etc/ssl/certs \
    --ro-bind /etc/ssl/certs /etc/ssl/certs --ro-bind /etc/fonts /etc/fonts \
    --ro-bind "$WORK/bootstrap-etc/passwd" /etc/passwd --ro-bind "$WORK/bootstrap-etc/group" /etc/group \
    --ro-bind "$WORK/bootstrap-etc/nsswitch.conf" /etc/nsswitch.conf --ro-bind "$WORK/bootstrap-etc/hosts" /etc/hosts \
    --ro-bind "$WORK/bootstrap-etc/resolv.conf" /etc/resolv.conf --ro-bind "$WORK/bootstrap-etc/os-release" /etc/os-release \
    --ro-bind "$WORK/bootstrap-etc/npm-user.npmrc" /etc/npm-user.npmrc --ro-bind "$WORK/bootstrap-etc/npm-global.npmrc" /etc/npm-global.npmrc \
    --proc /proc --dev /dev --tmpfs /run --tmpfs /tmp --dir /home --dir /home/bootstrap --dir /opt --dir /opt/portable \
    --dir /opt/portable/node --bind "$WORK/node" /opt/portable/node \
    --dir /opt/portable/prefix --bind "$WORK/claude-prefix" /opt/portable/prefix \
    --dir /opt/portable/cache --bind "$WORK/npm-cache" /opt/portable/cache \
    --setenv HOME /home/bootstrap --setenv PATH /opt/portable/node/bin:/usr/bin:/bin \
    --setenv TZ UTC \
    --setenv npm_config_userconfig /etc/npm-user.npmrc --setenv npm_config_globalconfig /etc/npm-global.npmrc \
    --setenv npm_config_registry https://registry.npmjs.org/ --setenv npm_config_prefix /opt/portable/prefix \
    --setenv npm_config_cache /opt/portable/cache -- "$@"
}

# Package Ubuntu's official Git build and all ELF shared objects it uses. The
# executable and helpers run from the staged session tree, never from PATH on
# the host; dpkg-deb only unpacks archives and does not install packages.
mkdir -p "$WORK/git/debs" "$WORK/git/root"
(cd "$WORK/git/debs" && apt-get download git >/dev/null)
GIT_DEB=$(find "$WORK/git/debs" -maxdepth 1 -name 'git_*.deb' -print -quit)
[[ -n $GIT_DEB ]] || { echo 'Could not download the Ubuntu Git package.' >&2; exit 1; }
dpkg-deb -x "$GIT_DEB" "$WORK/git/root"
GIT_BIN="$WORK/git/root/usr/bin/git"
[[ -x $GIT_BIN ]] || { echo 'Downloaded Git package has no runnable git executable.' >&2; exit 1; }
while IFS= read -r elf; do
  while read -r lib; do
    [[ $lib = /* && -e $lib ]] || continue
    cp -L --parents -- "$lib" "$WORK/git/root"
  done < <(ldd "$elf" 2>/dev/null | sed -nE 's/.*=> ([^ ]+) .*/\1/p; s/^\s*(\/[^ ]+) .*/\1/p')
done < <(find "$WORK/git/root/usr" -type f -executable -print)
tar -C "$WORK/git/root" -czf "$TOOLS/git-runtime.tar.gz" .

# Use the just-verified official Node/npm distribution to fetch the official
# Claude Code package at the latest stable registry version. npm validates the
# registry's dist.integrity while fetching; retain that metadata and tree as a
# session-staging archive so the USB itself needs no executable symlinks.
mkdir -p "$WORK/claude-prefix"
mkdir -p "$WORK/npm-cache" "$WORK/bootstrap-home"
CLAUDE_META=$(run_bubblewrap /opt/portable/node/bin/node /opt/portable/node/lib/node_modules/npm/bin/npm-cli.js view @anthropic-ai/claude-code@latest --json)
CLAUDE_VER=$(printf '%s' "$CLAUDE_META" | "$NODE" -e 'let s="";process.stdin.on("data",x=>s+=x).on("end",()=>process.stdout.write(JSON.parse(s).version))')
CLAUDE_INTEGRITY=$(printf '%s' "$CLAUDE_META" | "$NODE" -e 'let s="";process.stdin.on("data",x=>s+=x).on("end",()=>process.stdout.write(JSON.parse(s).dist.integrity))')
[[ $CLAUDE_VER =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $CLAUDE_INTEGRITY =~ ^sha512-[A-Za-z0-9+/]+=*$ ]] || { echo 'Claude Code latest registry metadata was invalid.' >&2; exit 1; }
run_bubblewrap /opt/portable/node/bin/node /opt/portable/node/lib/node_modules/npm/bin/npm-cli.js install --global --prefix /opt/portable/prefix --no-fund --no-audit "@anthropic-ai/claude-code@${CLAUDE_VER}"
CLAUDE_MANIFEST="$WORK/claude-prefix/lib/node_modules/@anthropic-ai/claude-code/package.json"
[[ -f $CLAUDE_MANIFEST ]] || { echo 'Claude Code package did not install.' >&2; exit 1; }
[[ $("$NODE" -e 'process.stdout.write(require(process.argv[1]).version)' "$CLAUDE_MANIFEST") == "$CLAUDE_VER" ]] || { echo 'Claude Code installed version did not match registry metadata.' >&2; exit 1; }
# npm has recently published the Linux native executable as an optional
# platform package. Install it explicitly because npm may skip failed optional
# dependencies while returning success for the small JS wrapper package.
run_bubblewrap /opt/portable/node/bin/node /opt/portable/node/lib/node_modules/npm/bin/npm-cli.js install \
  --prefix /opt/portable/prefix/lib/node_modules/@anthropic-ai/claude-code --no-save --no-package-lock --no-fund --no-audit \
  "@anthropic-ai/claude-code-linux-x64@${CLAUDE_VER}"
run_bubblewrap /opt/portable/node/bin/node /opt/portable/prefix/lib/node_modules/@anthropic-ai/claude-code/install.cjs
CLAUDE_BIN_REL=$("$NODE" -e 'const p=require(process.argv[1]);const b=typeof p.bin==="string"?p.bin:p.bin?.claude;if(typeof b!=="string"||b.startsWith("/")||b.includes("\\")||require("path").posix.normalize(b).startsWith("../"))process.exit(2);process.stdout.write(b)' "$CLAUDE_MANIFEST")
CLAUDE_BIN="$WORK/claude-prefix/lib/node_modules/@anthropic-ai/claude-code/$CLAUDE_BIN_REL"
[[ -x $CLAUDE_BIN && $(stat -c '%s' "$CLAUDE_BIN") -gt 4096 ]] || { echo 'Claude Linux executable is missing; refusing to package the wrapper stub.' >&2; exit 1; }
CLAUDE_VERSION_OUTPUT=$(run_bubblewrap /opt/portable/prefix/bin/claude --version)
[[ $CLAUDE_VERSION_OUTPUT == *"$CLAUDE_VER"* ]] || { echo "Claude Linux executable version did not match npm metadata: $CLAUDE_VERSION_OUTPUT" >&2; exit 1; }
echo "Verified Claude Code Linux executable: $CLAUDE_VERSION_OUTPUT"
mkdir -p "$WORK/claude-slots"
tar -C "$WORK/claude-prefix" -czf "$WORK/claude-package.tar.gz" .
CLAUDE_ARCHIVE_SHA=$(sha256sum "$WORK/claude-package.tar.gz" | awk '{print $1}')
CLAUDE_SLOT="slots/${CLAUDE_VER}-${CLAUDE_ARCHIVE_SHA:0:12}"
mkdir -p "$NPM/$CLAUDE_SLOT"
cp -- "$WORK/claude-package.tar.gz" "$NPM/$CLAUDE_SLOT/claude-package.tar.gz"
"$NODE" -e 'const fs=require("fs");const [p,v,i,h]=process.argv.slice(1);fs.writeFileSync(p,JSON.stringify({name:"@anthropic-ai/claude-code",version:v,registryIntegrity:i,archiveSha256:h,source:"npm-registry-integrity-verified"},null,2)+"\n",{mode:0o600})' "$NPM/$CLAUDE_SLOT/manifest.json" "$CLAUDE_VER" "$CLAUDE_INTEGRITY" "$CLAUDE_ARCHIVE_SHA"

# Pin and package Astral's official managed CPython 3.12.11 standalone build.
# Using its published release digest avoids relying on a host Python, uv cache,
# user config, or an ambient proxy while bootstrapping the interpreter itself.
PYTHON_FILE='cpython-3.12.11+20250612-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz'
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20250612/${PYTHON_FILE/+/%2B}"
PYTHON_SHA=15a3c9964e485f04d3c92739aca190616e09b2c4fac29b263432f6f29f00c6cf
PYTHON_SIZE=34395537
PYTHON_MIRROR_URL="https://releases.astral.sh/github/python-build-standalone/releases/download/20250612/${PYTHON_FILE/+/%2B}"
if [[ -f $TOOLS/python312-runtime.tar.gz ]] && echo "$PYTHON_SHA  $TOOLS/python312-runtime.tar.gz" | sha256sum --check --status; then
  cp -- "$TOOLS/python312-runtime.tar.gz" "$WORK/python312.tar.gz"
else
  download_verified_asset "$PYTHON_MIRROR_URL" "$PYTHON_URL" "$WORK/python312.tar.gz" "$PYTHON_SIZE" "$PYTHON_SHA" 300 300 "$PYTHON_URL"
  cp -- "$WORK/python312.tar.gz" "$TOOLS/python312-runtime.tar.gz"
fi
mkdir -p "$WORK/python"
tar -xzf "$WORK/python312.tar.gz" -C "$WORK/python" --strip-components=1
PYTHON_EXEC=$(find "$WORK/python" -type f -name python3.12 -print -quit)
[[ -x $PYTHON_EXEC ]] || { echo 'Managed Python archive is missing its Python 3.12 executable.' >&2; exit 1; }
PYTHON_VERSION=$(env -i PATH="$PATH" HOME="$WORK/download-home" "$PYTHON_EXEC" --version)
[[ $PYTHON_VERSION == 'Python 3.12.11' ]] || { echo "Managed Python version mismatch: $PYTHON_VERSION" >&2; exit 1; }
printf '{"version":"3.12.11","managedBy":"python-build-standalone 20250612","sourceSha256":"%s"}\n' "$PYTHON_SHA" > "$TOOLS/python312-manifest.json"

"$NODE" -e 'const fs=require("fs"),path=require("path"),crypto=require("crypto");const [out,root,node,uv,cc]=process.argv.slice(1);const names=["runtime/linux-x64/node-runtime.tar.xz","runtime/linux-x64/uv-runtime.tar.gz","runtime/linux-x64/bwrap-runtime.tar.gz","runtime/linux-x64/cc-switch.AppImage","tools/linux-x64/python312-runtime.tar.gz","tools/linux-x64/python312-manifest.json","tools/linux-x64/git-runtime.tar.gz"];const sha256={};for(const n of names)sha256[n]=crypto.createHash("sha256").update(fs.readFileSync(path.join(root,n))).digest("hex");fs.writeFileSync(out,JSON.stringify({platform:"linux",arch:"x64",versions:{node,uv,ccSwitch:cc},sha256},null,2)+"\n")' "$RT/manifest.json" "$ROOT" "$NODE_VER" "$UV_VER" "$CC_VER"
# Commit Claude's active package only after every managed runtime asset has
# passed validation and the final manifest has been written successfully.
"$NODE" -e 'const fs=require("fs");const [p,s,v,h]=process.argv.slice(1);fs.writeFileSync(p+".next",JSON.stringify({slot:s,version:v,archiveSha256:h})+"\n",{mode:0o600})' "$NPM/active.json" "$CLAUDE_SLOT" "$CLAUDE_VER" "$CLAUDE_ARCHIVE_SHA"
mv -f -- "$NPM/active.json.next" "$NPM/active.json"
echo "Linux x86_64 portable assets prepared at: $ROOT"
echo "CC Switch: v$CC_VER; Node: v$NODE_VER; uv: $UV_VER; Claude Code: $CLAUDE_VER"
