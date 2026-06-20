#!/usr/bin/env bash
# M9.R.14h.2 — pre-seed upstream tarballs whose origins throttle.
#
# Several from-source recipes pull tarballs from origins that rate-limit
# aggressively under the recipe's curl fetch action:
#
#   * cairographics.org — ~3 MB/min ceiling per IP.
#   * download.gnome.org — bursty 503 on consecutive misses.
#
# When the fetch action retries against a throttled origin the build
# stalls until the limiter releases (sometimes 5+ minutes for cairo).
# Pre-seeding the recipe's local fetch cache short-circuits the action's
# ``if [ ! -f <tarball> ]; then curl ...; fi`` gate, so the build moves
# straight to the sha256 verify + ``tar -xf`` extract.
#
# Each entry maps a recipe directory (under ``recipes/packages/source/``)
# to the upstream URL + sha256 of its primary source tarball. The hash
# MUST match the ``sha256:`` line in the recipe's ``repro.nim`` source
# block exactly; otherwise the action's ``sha256sum -c -`` invocation
# rejects the seeded artifact and the build short-fails.
#
# Usage:
#   tools/seed-throttled-tarballs.sh                # default: from-source root
#   REPRO_FROM_SOURCE_ROOT=/abs/path tools/seed...  # explicit override
#
# Idempotent: a recipe with the artifact already on disk is left alone.
# Recipes whose ``<recipeDir>`` is absent are skipped with a warning.
#
# Network: invokes ``curl --retry 5 --retry-delay 30`` and respects the
# throttle naturally (the long delay between retries means a single
# script invocation downloads the whole batch over a few minutes
# without ever bursting). Set ``SEED_TARBALLS_USE_WGET=1`` to swap to
# ``wget`` (more robust to ECONNRESET on some mirrors).

set -euo pipefail

REPRO_ROOT="${REPRO_FROM_SOURCE_ROOT:-$(pwd)/recipes/packages/source}"
if [[ ! -d "$REPRO_ROOT" ]]; then
  echo "seed-throttled-tarballs: from-source recipe root not found:" >&2
  echo "  $REPRO_ROOT" >&2
  echo "Pass REPRO_FROM_SOURCE_ROOT=<path> or run from the reprobuild repo root." >&2
  exit 1
fi

# Format: <recipe>|<url>|<sha256>
# Hashes pulled from the recipes' repro.nim source blocks on 2026-06-20.
# Keep this table in sync when a recipe bumps its upstream tarball.
ENTRIES=(
  "cairo|https://www.cairographics.org/releases/cairo-1.18.4.tar.xz|445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb"
  "pango|https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz|8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8"
  "gdk-pixbuf|https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz|b9505b3445b9a7e48ced34760c3bcb73e966df3ac94c95a148cb669ab748e3c7"
  "glib2|https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz|05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f"
  "harfbuzz|https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz|6ce3520f2d089a33cef0fc48321334b8e0b72141f6a763719aaaecd2779ecb82"
  "sway|https://github.com/swaywm/sway/archive/refs/tags/1.11.tar.gz|034ec4519326d6af5275814700dde46e852c5174614109affe4c86b2fbee062a"
)

seed_one() {
  local recipe="$1" url="$2" sha="$3"
  local recipe_dir="$REPRO_ROOT/$recipe"

  if [[ ! -d "$recipe_dir" ]]; then
    printf 'skip %s: recipe dir not present (%s)\n' "$recipe" "$recipe_dir" >&2
    return 0
  fi

  local fetch_dir="$recipe_dir/.repro/fetch"
  local target="$fetch_dir/$sha.tar"

  mkdir -p "$fetch_dir"

  if [[ -f "$target" ]]; then
    # Verify the existing artifact's hash so a partial/corrupt download
    # from an earlier abort is detected and re-fetched.
    local actual
    actual="$(sha256sum "$target" | awk '{print $1}')"
    if [[ "$actual" == "$sha" ]]; then
      printf 'present %s: %s\n' "$recipe" "$target"
      return 0
    fi
    printf 'corrupt %s: re-fetching (was %s, expected %s)\n' "$recipe" "$actual" "$sha"
    rm -f "$target"
  fi

  printf 'seeding %s from %s\n' "$recipe" "$url"
  if [[ "${SEED_TARBALLS_USE_WGET:-0}" = "1" ]]; then
    wget --tries=5 --waitretry=30 -q -O "$target" "$url"
  else
    curl -fsSL --retry 5 --retry-delay 30 -o "$target" "$url"
  fi

  local actual
  actual="$(sha256sum "$target" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    printf 'HASH MISMATCH %s: got %s expected %s\n' "$recipe" "$actual" "$sha" >&2
    rm -f "$target"
    return 1
  fi
  printf 'seeded %s: %s\n' "$recipe" "$target"
}

failed=0
for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r recipe url sha <<< "$entry"
  if ! seed_one "$recipe" "$url" "$sha"; then
    failed=$((failed + 1))
  fi
done

if (( failed > 0 )); then
  echo "seed-throttled-tarballs: $failed recipe(s) failed" >&2
  exit 1
fi
echo "seed-throttled-tarballs: complete"
