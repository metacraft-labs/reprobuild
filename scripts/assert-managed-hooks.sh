#!/usr/bin/env bash
# Assert the Reprobuild-managed git hooks for the checkout in $1 (default: $PWD).
# Run by the dev shell's shellHook on every entry (flake.nix).
#
# Never fails: a dev shell that refuses to open because a hook could not be
# written is worse than the drift. It says so loudly instead. The warning
# names the command that was actually run -- the same binary, the same path --
# with every word shell-quoted, so pasting it reproduces the failure even when
# the checkout path contains a space (spec/Unified-Locking-And-Hooks.md,
# "The named command must RUN where the message is printed").
#
# Tested by tests/test_dev_shell_hooks_warning_names_the_command_it_ran.sh.
root="${1:-$PWD}"
bin=""
if [ -x "$root/build/bin/repro" ]; then
	bin="$root/build/bin/repro"
elif command -v repro >/dev/null 2>&1; then
	bin="$(command -v repro)"
fi
if [ -n "$bin" ]; then
	"$bin" hooks ensure --vcs "$root" >/dev/null ||
		printf "warning: '%q hooks ensure --vcs %q' failed; the pre-push publication gate may be uninstalled. Run it by hand and read its diagnostic.\n" "$bin" "$root" >&2
else
	echo "warning: no 'repro' binary found; the pre-push publication gate cannot be asserted. Build it with 'just build' and re-enter the shell." >&2
fi
exit 0
