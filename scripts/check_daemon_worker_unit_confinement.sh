#!/usr/bin/env bash
# check_daemon_worker_unit_confinement.sh — CONF-1, CONF-3 and CONF-4 for the
# Distributed-Execution worker unit (deployment-security-architecture.md
# §4.4). The checks live in check_daemon_worker_unit_confinement.py (see its
# docstring: effective values under systemd's assignment semantics, validated
# list settings, exact omission arguments — threat model G33); this wrapper
# runs its self-test first, so a rule that stopped biting fails lint too.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_daemon_worker_unit_confinement.py --self-test
exec python3 scripts/check_daemon_worker_unit_confinement.py "$@"
