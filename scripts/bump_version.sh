#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

version="$1"
case "${version}" in
  *[!0-9.]*|"") echo "version must contain digits and dots only" >&2; exit 2 ;;
esac

perl -0pi -e "s/version = \"[^\"]+\"/version = \"${version}\"/" reprobuild.nimble
