#!/usr/bin/env bash
# Assemble get/dist/ — the static tree published to https://get.reprobuild.com.
#
# The install scripts are SINGLE-SOURCED from the repo's canonical installers:
#   /sh   <- install-on-distributions.sh   (the POSIX installer)
#   /pwsh <- install.ps1 if present, else get/pwsh.stub.ps1 (coming-soon stub)
# so get.reprobuild.com always re-serves the repo's real installer as text/plain
# (Content-Type forced by get/_headers). See
# metacraft-dev-guidelines/policies/product-install-domains.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
out="$here/dist"

rm -rf "$out"
mkdir -p "$out"

cp "$here/index.html" "$out/index.html"
cp "$here/_headers" "$out/_headers"

rev="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# /sh — keep the shebang on line 1, then inject a visible provenance/version
# header (policy §2.5), then the rest of the canonical installer verbatim.
# Which script backs /sh. See the M3 note below for the switch-over.
#   legacy (default) -> install-on-distributions.sh  (nix / local prefix)
#   repo             -> scripts/install/repro-install.sh (native repository)
case "${REPRO_GET_SH_SOURCE:-legacy}" in
  repo)   sh_src="$repo_root/scripts/install/repro-install.sh" ;;
  legacy) sh_src="$repo_root/install-on-distributions.sh" ;;
  *) echo "build-get.sh: unknown REPRO_GET_SH_SOURCE='${REPRO_GET_SH_SOURCE}' (want legacy|repo)" >&2; exit 2 ;;
esac
echo "build-get.sh: /sh <- ${sh_src#"$repo_root/"}"
{
  head -n 1 "$sh_src"
  printf '#\n'
  printf '# Reprobuild installer — served from https://get.reprobuild.com/sh\n'
  printf '# Source: metacraft-labs/reprobuild install-on-distributions.sh @ %s (assembled %s)\n' "$rev" "$now"
  printf '# Inspect before running:  curl -fsSL https://get.reprobuild.com/sh | less\n'
  printf '# Artifacts come from the release store (GitHub Releases / downloads.reprobuild.com).\n'
  printf '#\n'
  tail -n +2 "$sh_src"
} > "$out/sh"

# /pwsh — the PowerShell installer.
#
# M3 added scripts/install/repro-install.ps1, so the coming-soon stub is no
# longer what gets served. The legacy top-level install.ps1 (which never
# existed) is still honoured first so this does not silently change
# behaviour if someone adds one.
if [ -f "$repo_root/install.ps1" ]; then
  pwsh_src="$repo_root/install.ps1"
elif [ -f "$repo_root/scripts/install/repro-install.ps1" ]; then
  pwsh_src="$repo_root/scripts/install/repro-install.ps1"
else
  pwsh_src=''
fi
if [ -n "$pwsh_src" ]; then
  {
    printf '# Reprobuild installer — served from https://get.reprobuild.com/pwsh\n'
    printf '# Source: metacraft-labs/reprobuild %s @ %s (assembled %s)\n#\n' \
      "${pwsh_src#"$repo_root/"}" "$rev" "$now"
    cat "$pwsh_src"
  } > "$out/pwsh"
else
  cp "$here/pwsh.stub.ps1" "$out/pwsh"
fi

# ── M3: the native-repository installer, as its own endpoint ───────────────
#
# scripts/install/repro-install.sh is the M3 installer: it registers the
# apt/dnf/pacman repository and lets the package manager install, so
# updates afterwards come from `apt upgrade` rather than from re-running a
# script.
#
# It is served at /repo-sh and NOT (yet) at /sh, deliberately. The M3
# installer pins the SHA-256 of the release trust anchor and FAILS CLOSED
# when that pin is empty — which it is, because reprobuild has no release
# key yet (docs/release-signing.md, "Where the external boundary falls").
# Serving it at /sh today would replace a one-liner that works with one
# that refuses to run for everybody.
#
# THE SWITCH-OVER, in one place: when the release key exists and
# REPRO_KEYRING_SHA256 in scripts/install/repro-install.sh is populated,
# set REPRO_GET_SH_SOURCE=repo below (or export it) and /sh becomes the
# native-repository installer. That is the change that makes
#   curl https://install.reprobuild.com | sh
# install via apt. Until then /sh keeps its current nix/local-prefix
# behaviour and the M3 installer is fetchable, reviewable and testable at
# /repo-sh.
m3_sh="$repo_root/scripts/install/repro-install.sh"
if [ -f "$m3_sh" ]; then
  {
    head -n 1 "$m3_sh"
    printf '#\n'
    printf '# Reprobuild installer (native repository) — https://get.reprobuild.com/repo-sh\n'
    printf '# Source: metacraft-labs/reprobuild scripts/install/repro-install.sh @ %s (assembled %s)\n' "$rev" "$now"
    printf '# Inspect before running:  curl -fsSL https://get.reprobuild.com/repo-sh | less\n'
    printf '#\n'
    tail -n +2 "$m3_sh"
  } > "$out/repo-sh"
fi

echo "Assembled $out:"
ls -la "$out"
