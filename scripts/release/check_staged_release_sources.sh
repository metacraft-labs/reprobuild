#!/usr/bin/env bash
# check_staged_release_sources.sh
#
# The release job's installed-compile gate, runnable BEFORE a tag: stage
# share/repro exactly as the release does (stage_release_sources.sh) into a
# scratch package directory, then prove with check_release_source_closure.sh
# that the staged tree alone closes the compiles an installed reprobuild runs.
#
# WHY. Until now that gate ran only in .github/workflows/release.yml, after an
# hour of release builds, so a source-only input that compiled from the
# checkout but not from the archive surfaced only once a tag was pushed. v0.2.19
# was that case: test_certificates/cli.nim reads `../../test_certificates.nimble`
# at compile time, the archive carried `src/` alone, and the release failed at
# "Verify the archive builds a project from its own sources" on macOS. Every
# local build, the suite and the pre-push gate compile against the full
# checkout, where the file is present, so none of them could have seen it.
#
# It needs no build and no binaries: staging copies sources and the check is a
# `nim check` (no C compile) against the staged tree only. A few minutes on
# Linux and on Windows.
#
# Runs where stage_release_sources.sh runs: from the reprobuild checkout (this
# script changes to it), with the source-only inputs resolvable -- the dev
# shell's `*_SRC` variables on Linux/macOS, `. .\env.ps1` and the sibling
# checkouts on Windows (Git for Windows' bash) -- and `nim` on PATH.
#
# Keep TMPDIR OUTSIDE any workspace. The catalog half of the closure check
# looks for reprobuild-packages beside the ancestors of its scratch directory,
# so a scratch tree under a workspace finds the workspace's sibling first and
# fails with "sqlite3 resolved from <workspace>/reprobuild-packages, not from
# the archive's catalog" -- a property of where it ran, not of the archive.
#
#   bash scripts/release/check_staged_release_sources.sh
#   just release-source-closure
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

work=$(mktemp -d "${TMPDIR:-/tmp}/repro-staged-sources-XXXXXX")
# Staged copies of Nix store paths can be read-only; restore owner write so the
# scratch tree is always removable.
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work" 2>/dev/null || true' EXIT

bash scripts/release/stage_release_sources.sh "$work"
bash scripts/release/check_release_source_closure.sh "$work"
