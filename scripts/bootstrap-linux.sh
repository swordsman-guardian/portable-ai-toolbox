#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Download and package verified Linux x64 runtime assets for the portable USB
# tree. This script uses the host's existing tools only; it never installs an
# operating-system package or writes into the host's standard configuration.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then echo 'Run as a regular user; root is not needed.' >&2; exit 2; fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then echo 'Supported bootstrap target is Linux x86_64.' >&2; exit 2; fi
if [[ ! -r /etc/os-release ]]; then echo 'Unsupported packaging host: use Ubuntu 24.04 x86_64 to build the Linux runtime.' >&2; exit 2; fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then echo 'Unsupported packaging host: use Ubuntu 24.04 x86_64 to build the Linux runtime.' >&2; exit 2; fi
if (($# != 1)); then echo 'Usage: bootstrap-linux.sh /path/to/portable-root' >&2; exit 2; fi
ROOT=$(realpath -e -- "$1")
[[ -d $ROOT ]] || { echo 'Portable root must be an existing directory.' >&2; exit 2; }
for c in curl tar apt-get dpkg-deb ldd; do command -v "$c" >/dev/null || { echo "Missing host bootstrap utility: $c" >&2; exit 2; }; done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aistick-linux-bootstrap.XXXXXXXX")
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM
mkdir -p "$WORK/download-home"
safe_curl() { env -i PATH="$PATH" HOME="$WORK/download-home" /usr/bin/curl "$@"; }
RT="$ROOT/runtime/linux-x64"; TOOLS="$ROOT/tools/linux-x64"; NPM="$ROOT/npm-global/linux-x64"
mkdir -p -- "$RT" "$TOOLS" "$NPM"
NODE_VER=22.23.3
UV_VER=0.8.22
CC_VER=3.20.4

download_ranges() {
  local url=$1 output=$2 total=$3 chunk=4194304 start end index part size
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
      for job in "${jobs[@]}"; do wait "$job"; done
      jobs=()
    fi
    index=$((index+1))
  done
  for job in "${jobs[@]}"; do wait "$job"; done
  : > "$output"
  for ((index=0,start=0; start<total; index++,start+=chunk)); do
    part=$(printf '%s/%05d' "$parts" "$index")
    size=$(stat -c '%s' "$part")
    end=$((start+chunk)); ((end>total)) && end=$total
    [[ $size -eq $((end-start)) ]] || { echo "Range size mismatch for $url" >&2; exit 1; }
    cat -- "$part" >> "$output"
  done
  [[ $(stat -c '%s' "$output") -eq $total ]] || { echo "Downloaded size mismatch for $url" >&2; exit 1; }
}

safe_curl --fail --location --silent --show-error --retry 4 --retry-all-errors --connect-timeout 20 --max-time 120 "https://nodejs.org/dist/v${NODE_VER}/SHASUMS256.txt" -o "$WORK/node-shasums"
NODE_FILE="node-v${NODE_VER}-linux-x64.tar.xz"
NODE_SHA=$(awk -v f="$NODE_FILE" '$2 == f || $2 == "*" f {print $1; exit}' "$WORK/node-shasums")
[[ $NODE_SHA =~ ^[0-9a-f]{64}$ ]] || { echo 'Node official checksum record was missing.' >&2; exit 1; }
if [[ -f $RT/node-runtime.tar.xz ]] && echo "$NODE_SHA  $RT/node-runtime.tar.xz" | sha256sum --check --status; then
  cp -- "$RT/node-runtime.tar.xz" "$WORK/$NODE_FILE"
else
  safe_curl --fail --location --silent --show-error --retry 4 --retry-all-errors --connect-timeout 20 --max-time 300 "https://nodejs.org/dist/v${NODE_VER}/${NODE_FILE}" -o "$WORK/$NODE_FILE"
  echo "$NODE_SHA  $WORK/$NODE_FILE" | sha256sum --check --status || { echo 'Node archive checksum mismatch.' >&2; exit 1; }
  cp -- "$WORK/$NODE_FILE" "$RT/node-runtime.tar.xz"
fi
mkdir -p "$WORK/node"
tar -xJf "$WORK/$NODE_FILE" -C "$WORK/node" --strip-components=1
NODE="$WORK/node/bin/node"; NPM_CLI="$WORK/node/lib/node_modules/npm/bin/npm-cli.js"

UV_API=$(safe_curl --fail --location --silent --show-error --retry 4 --retry-all-errors --connect-timeout 20 --max-time 120 "https://api.github.com/repos/astral-sh/uv/releases/tags/${UV_VER}")
UV_SHA=$(printf '%s' "$UV_API" | "$NODE" -e 'let s="";process.stdin.on("data",x=>s+=x).on("end",()=>{let a=JSON.parse(s).assets.find(x=>x.name==="uv-x86_64-unknown-linux-gnu.tar.gz");process.stdout.write((a?.digest||"").replace(/^sha256:/,""))})')
UV_SIZE=$(printf '%s' "$UV_API" | "$NODE" -e 'let s="";process.stdin.on("data",x=>s+=x).on("end",()=>{let a=JSON.parse(s).assets.find(x=>x.name==="uv-x86_64-unknown-linux-gnu.tar.gz");process.stdout.write(String(a?.size||0))})')
[[ $UV_SHA =~ ^[0-9a-f]{64}$ ]] || { echo 'uv official release metadata has no SHA-256 digest.' >&2; exit 1; }
[[ $UV_SIZE =~ ^[0-9]+$ && $UV_SIZE -gt 0 ]] || { echo 'uv official release size metadata was invalid.' >&2; exit 1; }
if [[ -f $RT/uv-runtime.tar.gz ]] && echo "$UV_SHA  $RT/uv-runtime.tar.gz" | sha256sum --check --status; then
  cp -- "$RT/uv-runtime.tar.gz" "$WORK/uv.tar.gz"
else
  download_ranges "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-x86_64-unknown-linux-gnu.tar.gz" "$WORK/uv.tar.gz" "$UV_SIZE"
  echo "$UV_SHA  $WORK/uv.tar.gz" | sha256sum --check --status || { echo 'uv archive checksum mismatch.' >&2; exit 1; }
  cp -- "$WORK/uv.tar.gz" "$RT/uv-runtime.tar.gz"
fi

CC_URL="https://github.com/farion1231/cc-switch/releases/download/v${CC_VER}/CC-Switch-v${CC_VER}-Linux-x86_64.AppImage"
CC_SHA=c8d66d8193fd00fd12239bd06a8c50f517badbf50d9020a4662e95e907b318ef
if [[ -f $RT/cc-switch.AppImage ]] && echo "$CC_SHA  $RT/cc-switch.AppImage" | sha256sum --check --status; then
  echo 'Using the already verified official CC Switch AppImage.'
else
  download_ranges "$CC_URL" "$WORK/cc-switch.AppImage" 93010424
  echo "$CC_SHA  $WORK/cc-switch.AppImage" | sha256sum --check --status || { echo 'CC Switch official release checksum mismatch.' >&2; exit 1; }
  cp -- "$WORK/cc-switch.AppImage" "$RT/cc-switch.AppImage"
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
tar -C "$WORK/bwrap/root" -czf "$RT/bwrap-runtime.tar.gz" .

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
  "$BW" --clearenv --die-with-parent --new-session --unshare-user --unshare-pid --unshare-ipc --unshare-uts \
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
"$NODE" -e 'const fs=require("fs");const [p,s,v,h]=process.argv.slice(1);fs.writeFileSync(p+".next",JSON.stringify({slot:s,version:v,archiveSha256:h})+"\n",{mode:0o600})' "$NPM/active.json" "$CLAUDE_SLOT" "$CLAUDE_VER" "$CLAUDE_ARCHIVE_SHA"
mv -f -- "$NPM/active.json.next" "$NPM/active.json"

# Pin and package Astral's official managed CPython 3.12.11 standalone build.
# Using its published release digest avoids relying on a host Python, uv cache,
# user config, or an ambient proxy while bootstrapping the interpreter itself.
PYTHON_FILE='cpython-3.12.11+20250612-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz'
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20250612/${PYTHON_FILE/+/%2B}"
PYTHON_SHA=15a3c9964e485f04d3c92739aca190616e09b2c4fac29b263432f6f29f00c6cf
PYTHON_SIZE=34395537
if [[ -f $TOOLS/python312-runtime.tar.gz ]] && echo "$PYTHON_SHA  $TOOLS/python312-runtime.tar.gz" | sha256sum --check --status; then
  cp -- "$TOOLS/python312-runtime.tar.gz" "$WORK/python312.tar.gz"
else
  download_ranges "$PYTHON_URL" "$WORK/python312.tar.gz" "$PYTHON_SIZE"
  echo "$PYTHON_SHA  $WORK/python312.tar.gz" | sha256sum --check --status || { echo 'Official managed CPython archive checksum mismatch.' >&2; exit 1; }
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
echo "Linux x86_64 portable assets prepared at: $ROOT"
echo "CC Switch: v$CC_VER; Node: v$NODE_VER; uv: $UV_VER; Claude Code: $CLAUDE_VER"
