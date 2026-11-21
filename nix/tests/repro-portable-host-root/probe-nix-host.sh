#!/bin/sh
# `check <name> $?` deliberately reads the status of the test before it.
# shellcheck disable=SC2319
# Runs INSIDE the host-shaped root of run.sh with the host's /nix bound in: a
# /nix/store holding a marker file, and a `nix` at the default-profile path on
# PATH, the way a runner looks after a job installs Nix. `repro` resolves from
# PATH. $HOME is fresh, so whatever the bundle extracts is visible.
#
# The bundle's sandbox puts its own store at /nix, so on such a host repro
# could not see the host's Nix (reprobuild-pm issue 2026-11-20 "repro-portable
# on a host with Nix hides the host's Nix"). The bundle must refuse instead.
#
# usage: probe-nix-host.sh <workspace-root>
#   <workspace-root> is the one-repo workspace probe.sh left behind; property
#   (3) runs `repro ws forall` in it.
# Prints one `PASS <name>` / `FAIL <name>` line per property and exits non-zero
# when any of them failed; run.sh asserts the lines.
set -u
ws=$1
fail=0
note() { printf '%s\n' "$*"; }
check() {
  if [ "$2" = 0 ]; then note "PASS $1"; else note "FAIL $1"; fail=1; fi
}
show() { sed "s/^/  $1| /"; }

# The run.sh root must really be a host with Nix, or nothing below means
# anything.
if ! { [ -d /nix/store ] && [ -f /nix/store/host-nix-marker ] &&
  command -v nix >/dev/null 2>&1; }; then
  note "probe: no host /nix"
  exit 2
fi

cd "$ws/app" || exit 2

# ---- (1) the bundle refuses, saying why -------------------------------------
# A first run would extract the whole closure (minutes on a loaded builder); a
# refusing bundle returns at once, so the timeout covers the extraction.
out=$(timeout 3600 repro --version 2>&1)
rc=$?
note "$out" | show version
note "  version| exit=$rc"
[ "$rc" != 0 ] &&
  printf '%s\n' "$out" | grep -q 'refusing to start: this host has Nix (/nix/store exists)'
check "refuses-on-a-nix-host" $?

# ---- (2) ... and names what to install instead ------------------------------
printf '%s\n' "$out" | grep -q 'the Nix package' &&
  printf '%s\n' "$out" | grep -q -- '--method nix' &&
  printf '%s\n' "$out" | grep -q 'the release archive reprobuild-<version>-linux-<arch>.tar.gz'
check "refusal-names-what-to-install" $?

# ---- (3) repro never runs with the host's Nix hidden ------------------------
# Either the bundle refuses, or a command repro spawns can see the host's
# store. The unguarded bundle does neither: it runs, and inside its sandbox
# /nix is its own store, so the host's marker is gone. `nix` stays on the kept
# PATH there and names a path that no longer exists, which is how a
# `useFlakeDevShell()` project fails under it.
# forall echoes the command it runs, so the token the command prints is built
# at run time and never appears in the command text, so the single quotes
# are the point.
# shellcheck disable=SC2016
out=$(timeout 900 repro ws forall --workspace-root="$ws" \
  -c 'test -f /nix/store/host-nix-marker && echo "HOST_NIX_$((6 * 7))_VISIBLE"' 2>&1)
rc=$?
note "$out" | show forall
note "  forall| exit=$rc"
if printf '%s\n' "$out" | grep -q 'HOST_NIX_42_VISIBLE'; then
  true
else
  [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q 'refusing to start: this host has Nix'
fi
check "host-nix-never-hidden" $?

# ---- (4) the refusal comes before extraction --------------------------------
# A refused run must not leave an ~800 MB extracted closure behind in $HOME
# (arx extracts to $HOME/.cache/tmpx-<hash>).
extracted=0
for d in "$HOME"/.cache/tmpx-*; do
  [ -e "$d" ] || continue
  note "$d" | show extracted
  extracted=1
done
[ "$extracted" = 0 ]
check "refuses-before-extracting" $?

exit "$fail"
