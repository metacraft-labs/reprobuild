# shellcheck shell=bash
# shellcheck disable=SC2034  # the RUNQUOTA_LEASE_* variables are outputs read by the sourcing script
# Which RunQuota daemon does a script's `runquota acquire` lease from?
#
#   . scripts/lib/runquota_lease_endpoint.sh
#   if runquota_lease_endpoint_find; then
#     RUNQUOTA_SOCKET="$RUNQUOTA_LEASE_SOCKET" \
#       RUNQUOTA_ENDPOINT_SCOPE="$RUNQUOTA_LEASE_SCOPE" \
#       runquota acquire --cpu 1000 --mem 2GiB -- <command>
#   fi
#
# `runquota acquire` is RunQuota's bridge for shell scripts: it requests a
# lease, waits for the grant, runs the command under it and releases it. The
# CLI on its own reaches only RUNQUOTA_SOCKET or the host
# service's fixed rendezvous; it does not look for the shared per-user daemon
# that `repro` adopts or starts on an unprovisioned host. A script that leased
# only from the host service would therefore lease from nothing on exactly the
# hosts where every `repro` build already shares one daemon. So this helper
# looks where `repro` looks, in the same order, and answers only with a daemon
# that answers a `status`:
#
#   1. the caller's RUNQUOTA_SOCKET (with the caller's RUNQUOTA_ENDPOINT_SCOPE);
#   2. the provisioned host service, at its rendezvous socket;
#   3. the user's shared per-user daemon, at the directory RunQuota's
#      `userEndpointDir` (runquota_ipc) computes (RUNQUOTA_USER_ENDPOINT_DIR; else
#      /run/user/<euid>/runquota when /run/user/<euid> is a real directory
#      the user owns with no group or other write; else /tmp/runquota-<euid>),
#      under the private endpoint policy.
#
# It never starts a daemon: the adopt-or-start launcher, its start lock and its
# handover live in reprobuild's engine, and a second launcher written in shell
# would be a second implementation of that protocol. A host where none answers
# has no coordinator to lease from, and the caller decides what to do then.
#
# Inputs (all optional): RUNQUOTA_SOCKET, RUNQUOTA_ENDPOINT_SCOPE,
# RUNQUOTA_USER_ENDPOINT_DIR, RUNQUOTA_BIN (the `runquota` CLI, else PATH),
# REPRO_HOST_RUNQUOTA_SOCKETS (space-separated host rendezvous sockets to try,
# default /run/runquota/runquotad.sock /var/run/runquota/runquotad.sock; tests
# point it at a socket of their own), REPRO_RUNQUOTA_RUN_USER_ROOT (default
# /run/user on Linux; tests point it elsewhere).
#
# Outputs: RUNQUOTA_LEASE_CLI, RUNQUOTA_LEASE_SOCKET, RUNQUOTA_LEASE_SCOPE (empty
# or `private`) and RUNQUOTA_LEASE_REASON (one line naming the daemon, or why
# there is none). Returns 0 when a daemon answers, 1 when none does.

# True when a daemon answers a `status` on socket $1 under endpoint scope $2. A
# socket file alone is not an answer: a stale one outlives its daemon.
runquota_lease_endpoint_answers() {
	local sock="$1" scope="$2"
	[[ -S "${sock}" ]] || return 1
	if [[ -n "${scope}" ]]; then
		RUNQUOTA_SOCKET="${sock}" RUNQUOTA_ENDPOINT_SCOPE="${scope}" \
			"${RUNQUOTA_LEASE_CLI}" status >/dev/null 2>&1
	else
		(unset RUNQUOTA_ENDPOINT_SCOPE
			RUNQUOTA_SOCKET="${sock}" "${RUNQUOTA_LEASE_CLI}" status >/dev/null 2>&1)
	fi
}

# The per-user endpoint directory, by the spec's three-step rule.
runquota_lease_user_endpoint_dir() {
	local euid run_user_root runtime mode
	euid="$(id -u)"
	if [[ -n "${RUNQUOTA_USER_ENDPOINT_DIR:-}" ]]; then
		printf '%s\n' "${RUNQUOTA_USER_ENDPOINT_DIR}"
		return 0
	fi
	run_user_root="${REPRO_RUNQUOTA_RUN_USER_ROOT-}"
	if [[ -z "${REPRO_RUNQUOTA_RUN_USER_ROOT+set}" && "$(uname -s)" == Linux ]]; then
		run_user_root=/run/user
	fi
	if [[ -n "${run_user_root}" ]]; then
		runtime="${run_user_root}/${euid}"
		# A real directory (not a symbolic link), owned by the effective uid,
		# with no group or other write permission.
		# `stat -c` is GNU; macOS's stat spells it `-f '%Lp'`.
		mode="$(stat -c '%a' "${runtime}" 2>/dev/null || stat -f '%Lp' "${runtime}" 2>/dev/null || echo 777)"
		if [[ -d "${runtime}" && ! -L "${runtime}" && -O "${runtime}" ]] &&
			(( (8#${mode} & 8#022) == 0 )); then
			printf '%s\n' "${runtime}/runquota"
			return 0
		fi
	fi
	printf '%s\n' "/tmp/runquota-${euid}"
}

runquota_lease_endpoint_find() {
	local sock user_sock
	RUNQUOTA_LEASE_SOCKET=""
	RUNQUOTA_LEASE_SCOPE=""
	RUNQUOTA_LEASE_CLI="${RUNQUOTA_BIN:-$(command -v runquota 2>/dev/null || true)}"
	if [[ -z "${RUNQUOTA_LEASE_CLI}" || ! -x "${RUNQUOTA_LEASE_CLI}" ]]; then
		RUNQUOTA_LEASE_REASON="no runquota CLI (RUNQUOTA_BIN or PATH)"
		return 1
	fi
	if [[ -n "${RUNQUOTA_SOCKET:-}" ]]; then
		if runquota_lease_endpoint_answers "${RUNQUOTA_SOCKET}" "${RUNQUOTA_ENDPOINT_SCOPE:-}"; then
			RUNQUOTA_LEASE_SOCKET="${RUNQUOTA_SOCKET}"
			RUNQUOTA_LEASE_SCOPE="${RUNQUOTA_ENDPOINT_SCOPE:-}"
			RUNQUOTA_LEASE_REASON="the caller's RUNQUOTA_SOCKET (${RUNQUOTA_SOCKET})"
			return 0
		fi
		# The caller named a daemon and it does not answer. Looking elsewhere
		# would lease from a daemon the caller did not choose.
		RUNQUOTA_LEASE_REASON="the caller's RUNQUOTA_SOCKET (${RUNQUOTA_SOCKET}) does not answer"
		return 1
	fi
	for sock in ${REPRO_HOST_RUNQUOTA_SOCKETS:-/run/runquota/runquotad.sock /var/run/runquota/runquotad.sock}; do
		if runquota_lease_endpoint_answers "${sock}" ""; then
			RUNQUOTA_LEASE_SOCKET="${sock}"
			RUNQUOTA_LEASE_REASON="the host service at ${sock}"
			return 0
		fi
	done
	user_sock="$(runquota_lease_user_endpoint_dir)/runquotad.sock"
	if runquota_lease_endpoint_answers "${user_sock}" private; then
		RUNQUOTA_LEASE_SOCKET="${user_sock}"
		RUNQUOTA_LEASE_SCOPE=private
		RUNQUOTA_LEASE_REASON="the user's shared per-user daemon at ${user_sock}"
		return 0
	fi
	RUNQUOTA_LEASE_REASON="no RunQuota daemon answers (no RUNQUOTA_SOCKET, no host service, none at ${user_sock})"
	return 1
}
