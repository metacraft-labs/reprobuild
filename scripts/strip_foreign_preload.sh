# shellcheck shell=bash
# Source this from a test runner: it removes any LD_PRELOAD / DYLD_INSERT_LIBRARIES
# the runner inherited, and says so on stderr.
#
# Why. A test that runs a monitored action relies on io-mon putting its own shim
# first in the child's preload list; a test that reads a tool's output relies on
# that output being the tool's alone. An inherited preload breaks both. Measured
# 2026-11-01: an agent session inherits agent-harbor's command-trace shim
# (`libah_command_trace_shim.so`), which drops io-mon's shim from every
# monitored root on spawn (reprobuild-pm issue
# 2026-11-01-monitored-root-reports-no-process-start-on-nixos-ci-bare-002), and
# which prints its own line on a tool's output -- enough to turn a red
# `t_addon_preflight_needs_a_c_compiler` green. A test result taken under a
# foreign preload is not a result about this tree, so the runner strips it;
# `scripts/build_apps.sh` does the same for the build.
#
# The engine's own monitoring sets LD_PRELOAD for the children it spawns; that
# happens after this, inside the run, and is not affected.
if [ -n "${LD_PRELOAD:-}" ] || [ -n "${DYLD_INSERT_LIBRARIES:-}" ]; then
  echo "$(basename "$0"): ignoring the inherited preload" \
    "(LD_PRELOAD='${LD_PRELOAD:-}' DYLD_INSERT_LIBRARIES='${DYLD_INSERT_LIBRARIES:-}')" >&2
fi
unset LD_PRELOAD DYLD_INSERT_LIBRARIES
