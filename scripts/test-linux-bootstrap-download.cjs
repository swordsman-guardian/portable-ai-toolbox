'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname, 'bootstrap-linux.sh'), 'utf8');
const rangesStart = source.indexOf('download_ranges() {');
const verifiedStart = source.indexOf('download_verified_asset() {');
const helperEnd = source.indexOf('\nif [[ $MODE == prepare ]]; then', verifiedStart);
assert.ok(rangesStart >= 0 && verifiedStart > rangesStart && helperEnd > verifiedStart,
  'bootstrap download helper definitions must exist');

// Exercise the actual bootstrap functions in a temporary fixture. Only the
// curl executable is redirected to a deterministic synthetic downloader.
const helperSource = source.slice(source.indexOf('safe_curl() {'), helperEnd)
  .replaceAll('/usr/bin/curl', '"$CURL_BIN"');
assert.ok(helperSource.includes('download_verified_asset() {'));
assert.ok(helperSource.includes('download_ranges() {'));

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'aistick-linux-download-test-'));
try {
  const payloadSize = 20 * 1024 * 1024;
  const payload = path.join(fixture, 'good-payload');
  const badPayload = path.join(fixture, 'bad-payload');
  fs.writeFileSync(payload, Buffer.alloc(payloadSize, 0x41));
  fs.writeFileSync(badPayload, Buffer.alloc(payloadSize, 0x42));
  const expectedSha = crypto.createHash('sha256').update(fs.readFileSync(payload)).digest('hex');
  const mockCurl = path.join(fixture, 'mock-curl');
  fs.writeFileSync(mockCurl, `#!/usr/bin/env bash
set -euo pipefail
out=
range=
scenario=
while (($#)); do
  case $1 in
    --range) range=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    synthetic-*) arg=${'${1#synthetic-}'}; scenario=${'${arg%-*}'}; shift ;;
    *) shift ;;
  esac
done
[[ -n $out ]] || exit 90
if [[ -z $range ]]; then
  case $scenario in
    full-valid) cp -- ${shellQuote(payload)} "$out" ;;
    full-bad) cp -- ${shellQuote(badPayload)} "$out" ;;
    range-bad) exit 22 ;;
    wait-cleanup) exit 22 ;;
    *) exit 91 ;;
  esac
  exit 0
fi
IFS=- read -r start end <<< "$range"
length=$((end-start+1))
case $scenario in
  full-bad|range-bad) head -c "$length" ${shellQuote(badPayload)} > "$out" ;;
  wait-cleanup)
    if [[ $start -eq 0 ]]; then exit 22; fi
    sleep 0.25
    marker_dir=$(dirname "$(dirname "$out")")
    : > "$marker_dir/child-$start.done"
    head -c "$length" /dev/zero > "$out"
    ;;
  *) exit 92 ;;
esac
`);
  fs.chmodSync(mockCurl, 0o755);

  function runScenario(name, scenario) {
    const work = path.join(fixture, `work-${name}`);
    const out = path.join(fixture, `result-${name}`);
    fs.mkdirSync(work, { recursive: true });
    const script = `#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/bin:/bin
export PATH
WORK=${shellQuote(work)}
ROOT=${shellQuote(fixture)}
CURL_BIN=${shellQuote(mockCurl)}
mkdir -p "$WORK/download-home"
${helperSource}
download_verified_asset synthetic-${scenario}-primary synthetic-${scenario}-fallback ${shellQuote(out)} ${payloadSize} ${expectedSha} 1 1 synthetic-${scenario}-range
`;
    const result = spawnSync('bash', ['-c', script], {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH || '/usr/bin:/bin',
        HOME: fixture,
      },
      timeout: 30000,
    });
    return { result, out, work };
  }

  const valid = runScenario('full-valid', 'full-valid');
  assert.equal(valid.result.status, 0, `valid full download should pass: ${valid.result.stderr}`);
  assert.deepEqual(fs.readFileSync(valid.out), fs.readFileSync(payload));
  assert.equal(fs.existsSync(`${valid.out}.full-download`), false);

  const completeBad = runScenario('full-bad', 'full-bad');
  assert.notEqual(completeBad.result.status, 0, 'complete bad bytes must fail checksum verification');
  assert.equal(fs.existsSync(completeBad.out), false, 'bad full and range bytes must not leave an accepted output');
  assert.equal(fs.existsSync(`${completeBad.out}.full-download`), false);

  const rangedBad = runScenario('range-bad', 'range-bad');
  assert.notEqual(rangedBad.result.status, 0, 'bad range bytes must fail checksum verification');
  assert.equal(fs.existsSync(rangedBad.out), false, 'bad ranged output must be removed');
  assert.equal(fs.existsSync(path.join(rangedBad.work, 'ranges-result-range-bad')), false,
    'range fragments must be removed after checksum failure');

  const cleanup = runScenario('wait-cleanup', 'wait-cleanup');
  assert.notEqual(cleanup.result.status, 0, 'a failed range child must fail the range download');
  assert.equal(fs.readdirSync(cleanup.work).filter((name) => name.startsWith('child-') && name.endsWith('.done')).length, 3,
    `the other children in the first four-job batch must finish before returning: ${cleanup.result.stderr}`);
  assert.equal(fs.existsSync(path.join(cleanup.work, 'ranges-result-wait-cleanup')), false,
    'failed range parts must be cleaned only after all launched children finish');

  process.stdout.write('Linux bootstrap download helpers passed synthetic full, bad-byte, range, and child-wait behavior checks.\n');
} finally {
  fs.rmSync(fixture, { recursive: true, force: true });
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}
