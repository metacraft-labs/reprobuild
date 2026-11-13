#!/usr/bin/env bash
# The test runner (scripts/run_tests.sh) uses the host's RunQuota daemon, and
# keeps a private per-user endpoint only where sharing would be wrong.
#
# scripts/lib/runquota_test_endpoint.sh holds the decision. This test sources
# the real helper and drives it against a REAL `runquotad`, started here on a
# socket under a `mktemp -d` and handed to the helper as the host service's
# rendezvous (REPRO_TEST_HOST_RUNQUOTA_SOCKETS): a provisioned host service
# lives under /run, which a test must neither use nor touch, so the daemon is a
# private one treated as the host's. Nothing is stubbed. The decision is read
# through the real `runquota status`.
#
# Cases: a host daemon that answers gives `host`; no daemon, and a stale socket
# file left by a dead daemon, give `private` (a socket file is not an answer);
# a caller's RUNQUOTA_SOCKET or RUNQUOTA_USER_ENDPOINT_DIR is honoured as
# `host`; REPRO_TEST_RUNQUOTA=private beats a live host daemon, =host beats an
# absent one; an unknown value is refused with status 2.
# Finally run_tests.sh itself is checked to source the helper and to create its
# private endpoint only in `private` mode. That last check reads the script's
# text, because running the whole suite is not a test of one decision.
#
# Falsifying mutation: a helper that always answers `private` fails the live
# host daemon case.
#
# `runquota` and `runquotad` are required (RUNQUOTA_BIN / RUNQUOTAD_BIN, a
# sibling ../runquota/build/bin, or PATH); a missing one FAILS the test.
#
#   bash tests/test_run_tests_runquota_endpoint.sh
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
daemon_pid=""
cleanup() {
	# Stop only the daemon started here, and only while the PID still names a
	# runquotad under this test's directory; never by name.
	if [ -n "$daemon_pid" ] && [ -r "/proc/$daemon_pid/cmdline" ] &&
		tr '\0' ' ' <"/proc/$daemon_pid/cmdline" | grep -qF -- "$work/"; then
		kill "$daemon_pid" 2>/dev/null || true
		wait "$daemon_pid" 2>/dev/null || true
	fi
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
export RUNQUOTA_BIN="$rq_cli"

# The environment of the run: nothing the caller's shell set may leak in.
unset RUNQUOTA_SOCKET RUNQUOTA_USER_ENDPOINT_DIR REPRO_TEST_RUNQUOTA \
	REPRO_TEST_HOST_RUNQUOTA_SOCKETS

# shellcheck source=scripts/lib/runquota_test_endpoint.sh
. "$repo/scripts/lib/runquota_test_endpoint.sh"

# decide <env assignments...>: the helper's answer under that environment, as
# "<mode>|<reason>", in a subshell so nothing leaks between cases.
decide() {
	(
		for a in "$@"; do export "${a?}"; done
		repro_test_runquota_decide
		printf '%s|%s\n' "$REPRO_TEST_RUNQUOTA_MODE" "$REPRO_TEST_RUNQUOTA_REASON"
	)
}
expect_mode() { # expect_mode <mode> <what> <env...>
	local want="$1" what="$2" got
	shift 2
	got="$(decide "$@")"
	[ "${got%%|*}" = "$want" ] || fail "$what: expected '$want', got '$got'"
	echo "PASS: $what -> $want (${got#*|})"
}

host_dir="$work/host"
mkdir -m 700 "$host_dir"
host_sock="$host_dir/runquotad.sock"

# 1. No daemon and no socket file at all: private.
expect_mode private "no host service" "REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"

# 2. A stale socket file (a dead daemon's leftover): still private, because the
#    file is not an answer. A real, bound, abandoned socket is made by a
#    daemon that is then stopped without cleaning up (SIGKILL).
"$rq_daemon" --socket "$host_sock" \
	--host-config "$host_dir/host.toml" --host-identity-file "$host_dir/host-id" \
	--estimate-db "$host_dir/estimates.sqlite" --no-write-stats \
	--ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
	--cpu-milli 4000 --memory-bytes 8589934592 >"$host_dir/daemon.log" 2>&1 &
daemon_pid="$!"
for _ in $(seq 1 200); do
	grep -q "runquotad listening" "$host_dir/daemon.log" 2>/dev/null && break
	kill -0 "$daemon_pid" 2>/dev/null || {
		cat "$host_dir/daemon.log" >&2
		fail "the stand-in host daemon exited before it listened"
	}
	sleep 0.05
done
grep -q "runquotad listening" "$host_dir/daemon.log" || fail "the stand-in host daemon never listened"

# 3. The host daemon answers: host.
expect_mode host "a host service answers" "REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"
# A first candidate that does not exist does not hide a later one that answers.
expect_mode host "the second candidate answers" \
	"REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$work/nowhere.sock $host_sock"

# 2 (continued). Kill the daemon the hard way: the socket file stays behind.
kill -KILL "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=""
[ -S "$host_sock" ] || fail "the abandoned socket file was not left behind; case 2 would prove nothing"
expect_mode private "a stale socket file is not an answer" "REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"

# 4. The caller's own choices are honoured, even with no host daemon.
expect_mode host "an explicit RUNQUOTA_SOCKET" "RUNQUOTA_SOCKET=$work/x.sock" \
	"REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"
expect_mode host "an explicit RUNQUOTA_USER_ENDPOINT_DIR" "RUNQUOTA_USER_ENDPOINT_DIR=$work/u" \
	"REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"

# 5. The override beats what is found.
expect_mode host "REPRO_TEST_RUNQUOTA=host with no daemon" REPRO_TEST_RUNQUOTA=host \
	"REPRO_TEST_HOST_RUNQUOTA_SOCKETS=$host_sock"
expect_mode private "REPRO_TEST_RUNQUOTA=private beats an explicit socket" REPRO_TEST_RUNQUOTA=private \
	"RUNQUOTA_SOCKET=$work/x.sock"

# 6. An unknown value is refused, not guessed.
status=0
(REPRO_TEST_RUNQUOTA=maybe repro_test_runquota_decide) 2>"$work/err" || status=$?
[ "$status" = 2 ] || fail "an unknown REPRO_TEST_RUNQUOTA returned $status, expected 2"
grep -q "must be auto, host or private" "$work/err" || fail "the refusal does not say what is accepted"
echo "PASS: an unknown REPRO_TEST_RUNQUOTA is refused with status 2"

# 7. The runner uses the helper, and makes its private endpoint only for
#    `private`.
runner="$repo/scripts/run_tests.sh"
grep -q 'scripts/lib/runquota_test_endpoint.sh' "$runner" || fail "run_tests.sh does not source the helper"
grep -q 'repro_test_runquota_decide' "$runner" || fail "run_tests.sh does not call the decision"
awk '
	/export RUNQUOTA_USER_ENDPOINT_DIR=/ { if (!inprivate) bad = 1; found = 1 }
	/REPRO_TEST_RUNQUOTA_MODE.*== private/ { inprivate = 1 }
	/^    fi$/ { inprivate = 0 }
	END { exit (found && !bad) ? 0 : 1 }
' "$runner" || fail "run_tests.sh exports RUNQUOTA_USER_ENDPOINT_DIR outside the private branch"
echo "PASS: run_tests.sh creates its private endpoint only in private mode"

echo "ALL PASS: the test runner uses the host's RunQuota daemon unless sharing would be wrong"
