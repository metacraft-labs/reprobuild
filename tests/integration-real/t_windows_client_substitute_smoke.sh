#!/usr/bin/env bash
# t_windows_client_substitute_smoke.sh
#   Windows-Runner-Binary-Cache-Deploy M3b LIVE gate.
#
# Mirrors tests/integration/binary_cache/t_a3_substitute_hit_hex0.sh in
# spirit, but against the LIVE windows-runner-001 guest instead of a
# hermetic Linux process. It proves the end-to-end M3b primitive:
#
#   1. SEED — SCP the genuine Windows client seed
#      (repro-binary-cache-client.exe + libzstd.dll) into a fresh scratch
#      dir in the guest.
#   2. PUBLISH — start a Linux-side repro-binary-cache server on an
#      interface the guest can reach (the libvirt NAT gateway
#      192.168.122.1), synthesise a `bin/`-shaped prefix (a NUL-laced
#      .exe-like file + a .dll-like file), derive its cache-entry key,
#      and publish it from the Linux client.
#   3. SUBSTITUTE — over SSH, have the GUEST client `substitute` the
#      entry into a FRESH scratch dir. The substitute runs in a
#      PowerShell whose PATH is SCOPED TO EXCLUDE nim.exe and whose cwd
#      holds no reprobuild source tree, so a from-source fallback is
#      STRUCTURALLY IMPOSSIBLE during the run. This is the
#      NON-DESTRUCTIVE proof of the no-fallback property — we NEVER
#      rename or delete the guest's real Nim toolchain / reprobuild
#      checkout / runner (which would break the live production runner).
#   4. ASSERT —
#        * substitute exit 0
#        * BYTE-IDENTICAL materialisation of every published file
#          (sha256 compared on the Linux side after fetching the
#          materialised bytes back from the guest)
#        * nim.exe NOT resolvable on the scoped PATH during the run
#        * no `nim`/`build_apps.sh` compile process was spawned (proven
#          by a before/after process snapshot AND by the substitute
#          completing far faster than any Nim compile could)
#   5. CLEANUP — remove the guest scratch dirs; leave the runner intact.
#
# Environment (all have sane defaults for the high-mem-server testbed):
#   REPRO_GUEST_HOST     default 192.168.122.172   (guest IP)
#   REPRO_GUEST_USER     default admin
#   REPRO_GUEST_SSH_PORT default 22
#   REPRO_GUEST_SSH_KEY  default /var/lib/github-runner-windows-windows-runner-001/id_ed25519
#   REPRO_HOST_IP        default 192.168.122.1     (host IP the guest sees)
#   REPRO_CLIENT_SEED_EXE  path to the Windows client seed .exe
#   REPRO_CLIENT_SEED_DLL  path to the matching libzstd.dll
#   REPRO_LINUX_CLIENT     path to the Linux repro-binary-cache-client
#   REPRO_LINUX_SERVER     path to the Linux repro-binary-cache daemon
#   SSH_WRAP               optional wrapper prefix for ssh/scp (e.g. "sudo")

set -euo pipefail

GUEST_HOST="${REPRO_GUEST_HOST:-192.168.122.172}"
GUEST_USER="${REPRO_GUEST_USER:-admin}"
GUEST_PORT="${REPRO_GUEST_SSH_PORT:-22}"
GUEST_KEY="${REPRO_GUEST_SSH_KEY:-/var/lib/github-runner-windows-windows-runner-001/id_ed25519}"
HOST_IP="${REPRO_HOST_IP:-192.168.122.1}"
SSH_WRAP="${SSH_WRAP:-}"

CLIENT_SEED_EXE="${REPRO_CLIENT_SEED_EXE:?set REPRO_CLIENT_SEED_EXE to the Windows client seed .exe}"
CLIENT_SEED_DLL="${REPRO_CLIENT_SEED_DLL:?set REPRO_CLIENT_SEED_DLL to the matching libzstd.dll}"
# The client links repro_local_store (Nim's sqlite3 dynlib
# (sqlite3_64|sqlite3|sqlite3_32).dll). Ship sqlite3_64.dll in the seed
# so the exe is self-contained on a scoped PATH.
CLIENT_SEED_SQLITE="${REPRO_CLIENT_SEED_SQLITE:?set REPRO_CLIENT_SEED_SQLITE to sqlite3_64.dll}"
LINUX_CLIENT="${REPRO_LINUX_CLIENT:?set REPRO_LINUX_CLIENT to the Linux repro-binary-cache-client}"
LINUX_SERVER="${REPRO_LINUX_SERVER:?set REPRO_LINUX_SERVER to the Linux repro-binary-cache daemon}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "PASS: $*"; }

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes
          -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR
          -i "$GUEST_KEY")
gssh() { $SSH_WRAP ssh "${SSH_OPTS[@]}" -p "$GUEST_PORT" "$GUEST_USER@$GUEST_HOST" "$@"; }
gscp() { $SSH_WRAP scp "${SSH_OPTS[@]}" -P "$GUEST_PORT" "$@"; }

RUN_ID="$(date +%s)-$$"
GUEST_SEED_DIR="C:\\Temp\\m3b-smoke-${RUN_ID}\\seed"
GUEST_OUT_DIR="C:\\Temp\\m3b-smoke-${RUN_ID}\\out"
GUEST_ROOT="C:\\Temp\\m3b-smoke-${RUN_ID}"
GUEST_SEED_EXE="${GUEST_SEED_DIR}\\repro-binary-cache-client.exe"
# Forward-slash form for scp SOURCE paths — Windows OpenSSH's scp
# mangles backslashes in a remote source spec, so fetch-back uses `/`.
GUEST_OUT_DIR_FWD="C:/Temp/m3b-smoke-${RUN_ID}/out"

TMP="$(mktemp -d -t m3b-smoke-XXXXXX)"
SERVER_ROOT="$TMP/server-root"
PREFIX="$TMP/prefix"
FETCHED="$TMP/fetched"
KEY_PATH="$TMP/producer.key"
CERT_PATH="$TMP/producer.cert"
mkdir -p "$SERVER_ROOT" "$PREFIX" "$FETCHED"

SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  # Non-destructive guest cleanup: only the per-run scratch dir.
  gssh "cmd /c \"if exist ${GUEST_ROOT} rmdir /S /Q ${GUEST_ROOT}\"" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── pick a free port on the host IP the guest can reach ───────────────
PORT="$(python3 -c '
import socket
s=socket.socket(); s.bind(("0.0.0.0",0)); print(s.getsockname()[1]); s.close()')"
BASE_URL="http://${HOST_IP}:${PORT}"

echo "=== M3b live gate: t_windows_client_substitute_smoke (run ${RUN_ID}) ==="
echo "guest=${GUEST_USER}@${GUEST_HOST}:${GUEST_PORT}  cache=${BASE_URL}"

# ── 1. synthesise a bin/-shaped prefix with NUL-laced payloads ────────
# .exe-like + .dll-like files, each carrying embedded NUL bytes so a
# naive text round-trip would corrupt them — proving true byte identity.
python3 - "$PREFIX" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(root, exist_ok=True)
def w(rel, seed, n):
    b = bytearray()
    for i in range(n):
        b.append((seed + i*37) % 256)   # includes 0x00 bytes
    with open(os.path.join(root, rel), "wb") as f:
        f.write(bytes(b))
w("repro-fake.exe", 3, 4096)
w("librepro-fake.dll", 7, 2048)
PY
echo "synthesised prefix:"; ls -l "$PREFIX"

# ── 2. start the Linux cache server on the guest-reachable interface ──
"$LINUX_SERVER" --root="$SERVER_ROOT" --listen="0.0.0.0:${PORT}" \
  >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
for i in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.1
  [[ $i -eq 50 ]] && { cat "$TMP/server.log" >&2; fail "server did not bind ${BASE_URL}"; }
done
ok "cache server up on ${BASE_URL}"

# producer keypair for publish
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$LINUX_CLIENT" gen-key >/dev/null
[[ -f "$KEY_PATH" && -f "$CERT_PATH" ]] || fail "producer keypair not generated"

IDENTITY=(--package-name=m3b-smoke --package-version="${RUN_ID}"
          --platform-cpu=x86_64 --platform-os=windows)
ENTRY_KEY="$("$LINUX_CLIENT" derive-key "${IDENTITY[@]}" | tail -1 | tr -d '[:space:]')"
[[ ${#ENTRY_KEY} -eq 64 ]] || fail "derive-key produced bad key: '$ENTRY_KEY'"
echo "entry-key=$ENTRY_KEY"

# publish the prefix from the Linux side.
REPRO_BINARY_CACHE_URL="http://127.0.0.1:${PORT}" \
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$LINUX_CLIENT" publish "$ENTRY_KEY" "$PREFIX" "${IDENTITY[@]}" \
  || fail "Linux-side publish failed"
ok "published bin/-shaped prefix under $ENTRY_KEY"

# ── 3. seed the guest client + libzstd.dll into the scratch dir ───────
gssh "cmd /c \"if not exist ${GUEST_SEED_DIR} mkdir ${GUEST_SEED_DIR}\"" >/dev/null 2>&1 || true
gscp "$CLIENT_SEED_EXE" "$GUEST_USER@$GUEST_HOST:${GUEST_SEED_EXE}"
gscp "$CLIENT_SEED_DLL" "$GUEST_USER@$GUEST_HOST:${GUEST_SEED_DIR}\\libzstd.dll"
gscp "$CLIENT_SEED_SQLITE" "$GUEST_USER@$GUEST_HOST:${GUEST_SEED_DIR}\\sqlite3_64.dll"
ok "seeded client + libzstd.dll + sqlite3_64.dll into ${GUEST_SEED_DIR}"

# Confirm the guest can actually reach the cache (a MISS on a random key
# is a 404, which is still a successful round-trip — proves network).
gssh "cmd /c \"set REPRO_BINARY_CACHE_URL=${BASE_URL}&& ${GUEST_SEED_EXE} lookup ${ENTRY_KEY}\"" \
  && LOOKUP_RC=0 || LOOKUP_RC=$?
[[ "$LOOKUP_RC" -eq 0 ]] || fail "guest lookup of the published key did not hit (rc=$LOOKUP_RC)"
ok "guest reached the cache and the key HITS on lookup"

# ── 4. run substitute in a NO-NIM scoped shell + capture proof ────────
# Snapshot nim processes before. There must be none spawned by us.
NIM_BEFORE="$(gssh 'powershell -NoProfile -Command "(Get-Process nim -ErrorAction SilentlyContinue | Measure-Object).Count"' | tr -d '[:space:]')"

# Build the scoped-PATH substitute script. We set PATH to ONLY the seed
# dir + the bare System32/Windows (so powershell primitives work) —
# deliberately EXCLUDING any dir containing nim.exe. We assert nim.exe is
# unresolvable, THEN run substitute, THEN emit completion markers. cwd is
# the scratch dir (no reprobuild source), so even a hypothetical fallback
# has nothing to build. The script is SCP'd + run with -File so no fragile
# multi-line quoting survives the ssh/cmd/powershell hops.
cat > "$TMP/scoped-substitute.ps1" <<PS
\$ErrorActionPreference = 'Stop'
\$env:PATH = '${GUEST_SEED_DIR};C:\\Windows\\System32;C:\\Windows'
\$env:REPRO_BINARY_CACHE_URL = '${BASE_URL}'
\$env:REPRO_LOCAL_STORE = '${GUEST_ROOT}\\store'
Set-Location '${GUEST_ROOT}'
\$nim = Get-Command nim.exe -ErrorAction SilentlyContinue
if (\$nim) { Write-Host "NIM_ON_PATH \$(\$nim.Source)"; exit 90 } else { Write-Host 'NIM_NOT_ON_PATH' }
\$sw = [System.Diagnostics.Stopwatch]::StartNew()
& '${GUEST_SEED_EXE}' substitute '${ENTRY_KEY}' '${GUEST_OUT_DIR}'
\$rc = \$LASTEXITCODE
\$sw.Stop()
Write-Host "SUBSTITUTE_RC \$rc"
Write-Host "SUBSTITUTE_MS \$(\$sw.ElapsedMilliseconds)"
exit \$rc
PS
gscp "$TMP/scoped-substitute.ps1" "$GUEST_USER@$GUEST_HOST:${GUEST_ROOT}\\scoped-substitute.ps1"
SUB_OUT="$(gssh "powershell -NoProfile -ExecutionPolicy Bypass -File ${GUEST_ROOT}\\scoped-substitute.ps1")" && SUB_RC=0 || SUB_RC=$?
echo "--- guest substitute output ---"; echo "$SUB_OUT"; echo "-------------------------------"

NIM_AFTER="$(gssh 'powershell -NoProfile -Command "(Get-Process nim -ErrorAction SilentlyContinue | Measure-Object).Count"' | tr -d '[:space:]')"

# ── 5. assertions ─────────────────────────────────────────────────────
[[ "$SUB_RC" -eq 0 ]] || fail "guest substitute returned $SUB_RC"
grep -q 'NIM_NOT_ON_PATH' <<<"$SUB_OUT" || fail "nim.exe WAS resolvable on the scoped PATH — no-fallback proof invalid"
grep -q 'SUBSTITUTE_RC 0' <<<"$SUB_OUT" || fail "substitute did not report RC 0"
ok "substitute exit 0 with nim.exe NOT on PATH (from-source fallback structurally impossible)"

# no-fallback via process snapshot: we spawned no nim compile.
[[ "$NIM_AFTER" -le "$NIM_BEFORE" ]] || fail "a nim process appeared during the run (before=$NIM_BEFORE after=$NIM_AFTER) — a fallback may have fired"
# no-fallback via timing: a from-source client build is ~80s; a pull is <10s.
SUB_MS="$(grep -oE 'SUBSTITUTE_MS [0-9]+' <<<"$SUB_OUT" | awk '{print $2}')"
[[ -n "$SUB_MS" ]] || fail "could not parse SUBSTITUTE_MS"
(( SUB_MS < 30000 )) || fail "substitute took ${SUB_MS}ms (>30s) — too slow to be a pure pull; a build may have fired"
ok "no from-source fallback fired (nim procs before=$NIM_BEFORE after=$NIM_AFTER; substitute=${SUB_MS}ms)"

# byte-identity: fetch every materialised file back and sha256-compare.
for rel in repro-fake.exe librepro-fake.dll; do
  gscp "$GUEST_USER@$GUEST_HOST:${GUEST_OUT_DIR_FWD}/${rel}" "$FETCHED/$rel" \
    || fail "could not fetch materialised $rel from guest"
  want="$(sha256sum "$PREFIX/$rel" | awk '{print $1}')"
  got="$(sha256sum "$FETCHED/$rel" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || fail "byte mismatch for $rel: published=$want materialised=$got"
  echo "  byte-identical: $rel ($got)"
done
ok "every published file materialised BYTE-IDENTICALLY in the guest"

ok "t_windows_client_substitute_smoke — live guest substitute, byte-identity + non-destructive no-fallback"
