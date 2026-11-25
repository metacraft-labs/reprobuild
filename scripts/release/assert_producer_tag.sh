#!/usr/bin/env bash
# assert_producer_tag.sh <prefix> <tag> <expected-version>
#
# Refuse (exit 1) unless <tag> is `<prefix>/v<expected-version>-<n>`, where
# <n> is a producer build number (1, 2, ...). Exit 2 on a usage error.
#
# WHY. A toolchain producer workflow (for example
# .github/workflows/clingo-windows-arm64.yml) is started by pushing a tag, and
# it builds whatever version the tagged commit's pins name. The tag is what a
# reader sees in the release list and in the pinned download URL, so a tag
# that says one version while the commit builds another would publish an asset
# under a misleading name. The version in the tag must therefore be exactly the
# pinned version, and the suffix must be a plain build counter so two producer
# builds of the same version get distinct tags rather than a moved one.
set -euo pipefail

me="assert_producer_tag.sh"

if [ "$#" -ne 3 ]; then
  echo "usage: ${me} <prefix> <tag> <expected-version>" >&2
  exit 2
fi

prefix="$1"
tag="$2"
expected="$3"

if [ -z "${prefix}" ] || [ -z "${expected}" ]; then
  echo "${me}: prefix and expected version must be non-empty (is the version pin missing?)" >&2
  exit 2
fi
# The expected version is a dotted numeric release; anything else means the
# caller read the pin wrong, which must not pass as a mismatch or a match.
if ! [[ "${expected}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "${me}: expected version '${expected}' is not a dotted numeric version" >&2
  exit 2
fi

want_head="${prefix}/v"
if [[ "${tag}" != "${want_head}"* ]]; then
  echo "::error::${me}: tag '${tag}' is not under '${want_head}'" >&2
  exit 1
fi
rest="${tag#"${want_head}"}"
if ! [[ "${rest}" =~ ^([0-9]+(\.[0-9]+)*)-([1-9][0-9]*)$ ]]; then
  echo "::error::${me}: tag '${tag}' is not '${want_head}<version>-<n>' with <n> a build number from 1" >&2
  exit 1
fi
version="${BASH_REMATCH[1]}"
build="${BASH_REMATCH[3]}"
if [ "${version}" != "${expected}" ]; then
  echo "::error::${me}: tag '${tag}' names version ${version}, but the tagged commit pins ${expected}. Tag the version the commit builds." >&2
  exit 1
fi
echo "${me}: ${tag} is producer build ${build} of ${expected}."
