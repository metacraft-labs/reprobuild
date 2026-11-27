#!/usr/bin/env bash
# The lint's `nim check` sweep (scripts/check_nim_sources.sh, run by `just
# lint` inside every `git commit`) never starts one check per processor
# unadmitted. Where a RunQuota daemon answers, every check runs under its own
# `runquota acquire` lease and the daemon decides how many run; where none
# answers, at most a fixed small number run at a time.
#
# Regression test for the sweep running `nproc` checks at once, outside
# RunQuota, which took a 32-core shared host to 5 GB available (2026-11-26).
#
# THE TREE AND THE STUB. The real check_nim_sources.sh, the real
# scripts/source_paths.sh and the real scripts/lib/runquota_lease_endpoint.sh
# are copied into a scratch tree whose libs/libraries.txt and
# apps/entrypoints.txt list seventeen sources, one of them the engine's
# apps/repro/repro.nim. `nim` is a stub on PATH, and so is
# `nproc` (answering 32, the core count of the host the issue was observed on).
# Justification for the stubs: what is under test is how many checks the
# script starts at once and under whose admission, not what Nim reports. A
# real `nim check` of the real tree takes minutes and ~1 GiB per check, which
# would make this test the very load it guards against, and its duration
# would hide the concurrency the stub measures exactly. The stub records how
# many copies of itself run at once, and the RUNQUOTA_PARENT_LEASE that
# `runquota acquire` hands the command it launches under a grant -- the proof
# that a check ran leased -- and the memory the daemon granted that lease,
# read back from `runquota leases --json` while the check runs.
#
# THE DAEMONS ARE REAL. Each leased case starts a real `runquotad` on a socket
# under this test's `mktemp -d`, with a budget small enough that its admission
# is what bounds the sweep, and the script finds it the way it finds the real
# ones: as the per-user daemon (RUNQUOTA_USER_ENDPOINT_DIR, private scope), as
# the host service (REPRO_HOST_RUNQUOTA_SOCKETS), or through the caller's
# RUNQUOTA_SOCKET. A provisioned host service lives under /run, which a test
# must neither use nor touch.
#
# Cases:
#   1. No daemon answers: at most 4 checks run at once (the issue's 32 before
#      the fix), and the script says it is unleased and why.
#   2. The per-user daemon, CPU-bound (2 slots): every check is leased, at most
#      2 run at once, and the daemon granted one lease per check. Each check
#      reserves what it was measured to use: 2560 MiB, and 7 GiB for the
#      engine's apps/repro/repro.nim.
#   3. The host service, memory-bound (32 slots, 3 GiB, 1 GiB per check): at
#      most 3 run at once, and REPRO_LINT_CHECK_MEM is every check's
#      reservation, the engine's included.
#   4. A caller's RUNQUOTA_SOCKET that answers is used; one that does not
#      answer is not replaced by another daemon (unleased, bounded, named).
#   5. A failing check still fails the leased sweep, naming the source.
#   6. The per-user directory follows the spec's rule: /run/user/<euid> only
#      when it is a real directory the user owns with no group/other write.
#
# Falsifying mutation: restoring `jobs_max="${REPRO_LINT_JOBS:-$(nproc)}"` with
# no leases fails case 1 (16 at once) and cases 2 and 3 (no lease seen).
#
# `runquota` and `runquotad` are required (RUNQUOTA_BIN / RUNQUOTAD_BIN, a
# sibling ../runquota/build/bin, or PATH); a missing one FAILS the test.
#
#   bash tests/test_lint_nim_checks_are_admitted.sh
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
daemon_pids=()
cleanup() {
	# Stop only the daemons started here, and only while the PID still names
	# a runquotad under this test's directory; never by name.
	local pid
	for pid in ${daemon_pids[@]+"${daemon_pids[@]}"}; do
		if [ -r "/proc/$pid/cmdline" ] &&
			tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qF -- "$work/"; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	rm -rf "${work:?}"
}
trap cleanup EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

find_bin() { # find_bin <name> <override>
	local name="$1" override="$2"
	if [ -n "$override" ] && [ -x "$override" ]; then
		echo "$override"
	elif [ -x "$repo/../runquota/build/bin/$name" ]; then
		echo "$repo/../runquota/build/bin/$name"
	else
		command -v "$name" || true
	fi
}
rq_cli="$(find_bin runquota "${RUNQUOTA_BIN:-}")"
rq_daemon="$(find_bin runquotad "${RUNQUOTAD_BIN:-}")"
[ -n "$rq_cli" ] && [ -n "$rq_daemon" ] ||
	fail "runquota and runquotad are required (RUNQUOTA_BIN, RUNQUOTAD_BIN, ../runquota/build/bin or PATH)"

# The environment of the run: nothing the caller's shell set may leak in.
unset RUNQUOTA_SOCKET RUNQUOTA_ENDPOINT_SCOPE RUNQUOTA_USER_ENDPOINT_DIR \
	RUNQUOTA_PARENT_LEASE REPRO_HOST_RUNQUOTA_SOCKETS REPRO_LINT_JOBS \
	REPRO_LINT_CHECK_MEM REPRO_RUNQUOTA_RUN_USER_ROOT

# ---------------------------------------------------------------------------
# The scratch tree.
# ---------------------------------------------------------------------------
tree="$work/tree"
mkdir -p "$tree/scripts/lib" "$tree/apps" "$tree/libs" "$work/bin" "$work/src"
cp "$repo/scripts/check_nim_sources.sh" "$tree/scripts/"
cp "$repo/scripts/source_paths.sh" "$tree/scripts/"
cp "$repo/scripts/lib/runquota_lease_endpoint.sh" "$tree/scripts/lib/"
cp "$repo/scripts/test_parallelism.sh" "$tree/scripts/"
for i in $(seq 1 12); do echo "lib$i" >>"$tree/libs/libraries.txt"; done
for i in $(seq 1 4); do echo "app$i apps/app$i/app$i.nim --define:x" >>"$tree/apps/entrypoints.txt"; done
echo "repro apps/repro/repro.nim --define:ssl" >>"$tree/apps/entrypoints.txt"
total_checks=17

# The source roots check_nim_sources.sh resolves before it starts; each needs
# only its marker file.
for m in shm_queue.nim clispec.nim entrypoints.nim confutils.nim bearssl/abi/consttypes.nim; do
	mkdir -p "$work/src/$(dirname "$m")"
	: >"$work/src/$m"
done
export SHM_QUEUE_SRC="$work/src" CLI_SPEC_SRC="$work/src" ENTRYPOINTS_SRC="$work/src" \
	CONFUTILS_SRC="$work/src" BEARSSL_SRC="$work/src"

cat >"$work/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo 32
EOF
# The stub `nim`: counts the copies of itself running at once (under a lock,
# so two starts cannot both read the same count), records the lease it runs
# under and the memory that lease was granted (its `leases --json` record is
# the one labelled with this source; no `}` falls between a record's label
# and its memory_bytes), holds for a moment so concurrent copies overlap, and
# fails on a source named in $NIM_STUB_FAIL.
cat >"$work/bin/nim" <<'EOF'
#!/usr/bin/env bash
state="$NIM_STUB_STATE"
src="${*: -1}"
{
	flock 9
	n=$(($(cat "$state/running") + 1))
	echo "$n" >"$state/running"
	[ "$n" -gt "$(cat "$state/max")" ] && echo "$n" >"$state/max"
	echo "${RUNQUOTA_PARENT_LEASE:-none} $src" >>"$state/leases"
} 9>"$state/lock"
if [ -n "${RUNQUOTA_PARENT_LEASE:-}" ]; then
	mem="$("$RUNQUOTA_BIN" leases --json 2>/dev/null |
		grep -o "\"label\":\"just lint: nim check $src\"[^}]*\"memory_bytes\":[0-9]*" |
		sed 's/.*://' || true)"
	echo "$src ${mem:-unknown}" >>"$state/mem"
fi
sleep 0.4
{
	flock 9
	echo $(($(cat "$state/running") - 1)) >"$state/running"
} 9>"$state/lock"
if [ -n "${NIM_STUB_FAIL:-}" ] && [ "$src" = "$NIM_STUB_FAIL" ]; then
	echo "stub nim: refusing $src" >&2
	exit 1
fi
EOF
chmod +x "$work/bin/nproc" "$work/bin/nim"

# sweep <name> <env assignments...>: runs the real script in the scratch tree;
# leaves its output in $work/<name>.out, its status in $work/<name>.status and
# the stub's records in $work/<name>.state/.
sweep() {
	local name="$1" state="$work/$1.state" status=0
	shift
	mkdir -p "$state"
	echo 0 >"$state/running"
	echo 0 >"$state/max"
	: >"$state/leases"
	: >"$state/mem"
	(
		cd "$tree"
		for a in "$@"; do export "${a?}"; done
		PATH="$work/bin:$PATH" NIM_STUB_STATE="$state" RUNQUOTA_BIN="$rq_cli" \
			bash scripts/check_nim_sources.sh
	) >"$work/$name.out" 2>&1 || status=$?
	echo "$status" >"$work/$name.status"
}
max_of() { cat "$work/$1.state/max"; }
leased_count() { grep -cv '^none ' "$work/$1.state/leases" || true; }
# mem_of <sweep> <source>: the memory, in bytes, the lease of that check had.
mem_of() { sed -n "s|^$2 ||p" "$work/$1.state/mem"; }
show() {
	echo "--- $1 output ---" >&2
	cat "$work/$1.out" >&2
}

# start_daemon <socket> <scope> <cpu-milli> <memory-bytes>: a real runquotad,
# waited for until it listens.
start_daemon() {
	local sock="$1" scope="$2" cpu="$3" mem="$4" dir pid
	dir="$(dirname "$sock")"
	mkdir -p "$dir"
	chmod 700 "$dir"
	(
		# The daemon's own endpoint scope, set only in its subshell.
		# shellcheck disable=SC2030
		if [ -n "$scope" ]; then export RUNQUOTA_ENDPOINT_SCOPE="$scope"; fi
		exec "$rq_daemon" --socket "$sock" \
			--host-config "$dir/host.toml" --host-identity-file "$dir/host-id" \
			--estimate-db "$dir/estimates.sqlite" --no-write-stats \
			--ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
			--cpu-milli "$cpu" --memory-bytes "$mem"
	) >"$dir/daemon.log" 2>&1 &
	pid="$!"
	daemon_pids+=("$pid")
	for _ in $(seq 1 200); do
		grep -q "runquotad listening" "$dir/daemon.log" 2>/dev/null && return 0
		kill -0 "$pid" 2>/dev/null || {
			cat "$dir/daemon.log" >&2
			fail "the runquotad at $sock exited before it listened"
		}
		sleep 0.05
	done
	fail "the runquotad at $sock never listened"
}
gib=$((1024 * 1024 * 1024))
mib=$((1024 * 1024))
# Every case but the per-user ones points the per-user lookup at a directory
# with no daemon, so the developer's own per-user daemon is never found.
no_user="RUNQUOTA_USER_ENDPOINT_DIR=$work/no-user-daemon"
no_host="REPRO_HOST_RUNQUOTA_SOCKETS=$work/no-host.sock"

# ---------------------------------------------------------------------------
# 1. No daemon: a fixed bound, not the core count.
# ---------------------------------------------------------------------------
sweep unleased "$no_user" "$no_host"
[ "$(cat "$work/unleased.status")" = 0 ] || { show unleased; fail "the unleased sweep failed"; }
[ "$(max_of unleased)" -le 4 ] || { show unleased; fail "no daemon: $(max_of unleased) nim checks ran at once on a 32-processor host, expected at most 4"; }
[ "$(max_of unleased)" -ge 2 ] || { show unleased; fail "no daemon: the sweep ran serially ($(max_of unleased) at once)"; }
[ "$(leased_count unleased)" = 0 ] || fail "no daemon, yet a check ran under a lease"
grep -q "unleased, at most 4 nim checks at a time: no RunQuota daemon answers" "$work/unleased.out" ||
	{ show unleased; fail "the unleased sweep does not say that it is unleased, and why"; }
echo "PASS: no daemon -> unleased, at most $(max_of unleased) of $total_checks at once (32 processors)"

# REPRO_LINT_JOBS still overrides the bound.
sweep unleased-jobs "$no_user" "$no_host" REPRO_LINT_JOBS=1
[ "$(max_of unleased-jobs)" = 1 ] || fail "REPRO_LINT_JOBS=1 ran $(max_of unleased-jobs) at once"
echo "PASS: REPRO_LINT_JOBS overrides the unleased bound"

# ---------------------------------------------------------------------------
# 2. The user's shared per-user daemon, two CPU slots.
# ---------------------------------------------------------------------------
user_dir="$work/user-endpoint"
start_daemon "$user_dir/runquotad.sock" private 2000 $((64 * gib))
sweep per-user "RUNQUOTA_USER_ENDPOINT_DIR=$user_dir" "$no_host"
[ "$(cat "$work/per-user.status")" = 0 ] || { show per-user; fail "the leased sweep failed"; }
[ "$(leased_count per-user)" = "$total_checks" ] ||
	{ show per-user; fail "per-user daemon: $(leased_count per-user) of $total_checks checks ran under a lease"; }
[ "$(max_of per-user)" -le 2 ] ||
	{ show per-user; fail "per-user daemon with 2 CPU slots: $(max_of per-user) checks ran at once"; }
grep -q "leasing each nim check (1 CPU, .*) from the user's shared per-user daemon at $user_dir/runquotad.sock" "$work/per-user.out" ||
	{ show per-user; fail "the leased sweep does not name the daemon it leases from"; }
granted="$(RUNQUOTA_SOCKET="$user_dir/runquotad.sock" RUNQUOTA_ENDPOINT_SCOPE=private "$rq_cli" status |
	sed -n 's/^total_granted: //p')"
[ "$granted" = "$total_checks" ] || fail "the per-user daemon granted $granted leases, expected $total_checks"
echo "PASS: per-user daemon -> $total_checks leases, at most $(max_of per-user) at once (2 CPU slots)"
[ "$(mem_of per-user libs/lib1/src/lib1.nim)" = $((2560 * mib)) ] ||
	{ cat "$work/per-user.state/mem" >&2; fail "an ordinary check reserved $(mem_of per-user libs/lib1/src/lib1.nim) bytes, expected 2560 MiB"; }
[ "$(mem_of per-user apps/repro/repro.nim)" = $((7 * gib)) ] ||
	{ cat "$work/per-user.state/mem" >&2; fail "the engine check reserved $(mem_of per-user apps/repro/repro.nim) bytes, expected 7 GiB"; }
echo "PASS: each check reserves its measured class: 2560 MiB, and 7 GiB for the engine"

# ---------------------------------------------------------------------------
# 3. The host service, memory-bound: 32 slots but 3 GiB, 1 GiB per check.
# ---------------------------------------------------------------------------
host_sock="$work/host-endpoint/runquotad.sock"
start_daemon "$host_sock" "" 32000 $((3 * gib))
sweep host "$no_user" "REPRO_HOST_RUNQUOTA_SOCKETS=$work/absent.sock $host_sock" REPRO_LINT_CHECK_MEM=1GiB
[ "$(cat "$work/host.status")" = 0 ] || { show host; fail "the host-leased sweep failed"; }
[ "$(leased_count host)" = "$total_checks" ] || { show host; fail "host service: $(leased_count host) of $total_checks checks leased"; }
[ "$(max_of host)" -le 3 ] || { show host; fail "host service with 3 GiB at 1 GiB a check: $(max_of host) ran at once"; }
grep -q "from the host service at $host_sock" "$work/host.out" || { show host; fail "the host service is not named"; }
echo "PASS: host service -> leased, at most $(max_of host) at once (3 GiB, 1 GiB per check)"
[ "$(mem_of host apps/repro/repro.nim)" = "$gib" ] && [ "$(mem_of host libs/lib1/src/lib1.nim)" = "$gib" ] ||
	{ cat "$work/host.state/mem" >&2; fail "REPRO_LINT_CHECK_MEM=1GiB was not every check's reservation"; }
echo "PASS: REPRO_LINT_CHECK_MEM overrides every check's reservation"

# The host service wins over the per-user daemon, as for `repro`.
sweep both "RUNQUOTA_USER_ENDPOINT_DIR=$user_dir" "REPRO_HOST_RUNQUOTA_SOCKETS=$host_sock" REPRO_LINT_CHECK_MEM=1GiB
grep -q "from the host service at $host_sock" "$work/both.out" || { show both; fail "the per-user daemon was preferred over the host service"; }
echo "PASS: the host service is preferred over the per-user daemon"

# ---------------------------------------------------------------------------
# 4. The caller's RUNQUOTA_SOCKET.
# ---------------------------------------------------------------------------
sweep caller "RUNQUOTA_SOCKET=$user_dir/runquotad.sock" RUNQUOTA_ENDPOINT_SCOPE=private "$no_user" "REPRO_HOST_RUNQUOTA_SOCKETS=$host_sock"
grep -q "from the caller's RUNQUOTA_SOCKET ($user_dir/runquotad.sock)" "$work/caller.out" ||
	{ show caller; fail "the caller's RUNQUOTA_SOCKET was not used"; }
[ "$(leased_count caller)" = "$total_checks" ] || fail "caller's socket: not every check leased"
echo "PASS: the caller's RUNQUOTA_SOCKET is used"

sweep caller-dead "RUNQUOTA_SOCKET=$work/dead.sock" "RUNQUOTA_USER_ENDPOINT_DIR=$user_dir" "REPRO_HOST_RUNQUOTA_SOCKETS=$host_sock"
grep -q "unleased, at most 4 nim checks at a time: the caller's RUNQUOTA_SOCKET ($work/dead.sock) does not answer" "$work/caller-dead.out" ||
	{ show caller-dead; fail "a dead caller socket was replaced or not named"; }
[ "$(max_of caller-dead)" -le 4 ] || fail "dead caller socket: $(max_of caller-dead) at once"
echo "PASS: a caller's RUNQUOTA_SOCKET that does not answer is not replaced by another daemon"

# ---------------------------------------------------------------------------
# 5. A failing check fails the leased sweep.
# ---------------------------------------------------------------------------
sweep failing "RUNQUOTA_USER_ENDPOINT_DIR=$user_dir" "$no_host" NIM_STUB_FAIL=libs/lib7/src/lib7.nim
[ "$(cat "$work/failing.status")" != 0 ] || { show failing; fail "a failing check under a lease did not fail the sweep"; }
grep -q "libs/lib7/src/lib7.nim (exit 1)" "$work/failing.out" || { show failing; fail "the failing source is not named"; }
echo "PASS: a failing leased check fails the sweep and is named"

# ---------------------------------------------------------------------------
# 6. The per-user directory rule.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/runquota_lease_endpoint.sh
. "$repo/scripts/lib/runquota_lease_endpoint.sh"
euid="$(id -u)"
root="$work/run-user"
mkdir -p "$root/$euid"
chmod 700 "$root/$euid"
got="$(REPRO_RUNQUOTA_RUN_USER_ROOT="$root" runquota_lease_user_endpoint_dir)"
[ "$got" = "$root/$euid/runquota" ] || fail "a private runtime dir gave '$got'"
chmod 770 "$root/$euid"
got="$(REPRO_RUNQUOTA_RUN_USER_ROOT="$root" runquota_lease_user_endpoint_dir)"
[ "$got" = "/tmp/runquota-$euid" ] || fail "a group-writable runtime dir gave '$got', expected /tmp/runquota-$euid"
rm -rf "${root:?}/$euid"
mkdir -p "$work/elsewhere"
ln -s "$work/elsewhere" "$root/$euid"
got="$(REPRO_RUNQUOTA_RUN_USER_ROOT="$root" runquota_lease_user_endpoint_dir)"
[ "$got" = "/tmp/runquota-$euid" ] || fail "a symlinked runtime dir gave '$got'"
got="$(RUNQUOTA_USER_ENDPOINT_DIR=/x/y REPRO_RUNQUOTA_RUN_USER_ROOT="$root" runquota_lease_user_endpoint_dir)"
[ "$got" = /x/y ] || fail "RUNQUOTA_USER_ENDPOINT_DIR was not honoured: '$got'"
echo "PASS: the per-user endpoint directory follows the spec's three-step rule"

echo "ALL PASS: the lint's nim checks are admitted by RunQuota, or bounded where none answers"
