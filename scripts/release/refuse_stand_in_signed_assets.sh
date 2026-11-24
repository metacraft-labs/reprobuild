#!/bin/sh
# Refuse to publish a directory of release assets that holds anything signed
# with a stand-in (test) certificate.
#
#   refuse_stand_in_signed_assets.sh <staging-dir>
#
# Run by the release workflow's publish job on the staged assets, before
# anything is uploaded. Exits 1, naming each offender, when the directory
# holds
#
#   * a marker file `*.SIGNED-WITH-A-TEST-CERTIFICATE` (what
#     scripts/release-signing/repro-sign-installer.sh drops beside every
#     package it signs with a test certificate), or a stand-in root
#     (`*.stand-in-root.pem`); or
#   * a `.pkg` or `.msi` whose bytes contain the stand-in marker
#     `REPROBUILD UNTRUSTED TEST CERTIFICATE`. A signed package embeds its
#     signer certificate in DER (the .pkg in its CMS signature in the XAR
#     heap, the MSI in its DigitalSignature stream), and the marker is the
#     subject's organization, a plain UTF8String, so it appears verbatim. This
#     catches a stand-in-signed package whose marker file was lost. The
#     packages' payloads are compressed, so the literal does not occur in
#     them by accident; if it ever did, the release fails closed, here.
#
# Needs only POSIX sh and grep (the publish job has no dev environment).
# This is the last of three refusals: the signer refuses a test certificate on
# a publishing run (REPRO_RELEASE_PUBLISHING=1), and the release plan refuses
# to list a .pkg or .msi in .github/release-platforms.json while its
# production credentials are not configured.

set -eu

dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || { echo "usage: $0 <staging-dir>" >&2; exit 2; }

marker='REPROBUILD UNTRUSTED TEST CERTIFICATE'
bad=0
for f in "$dir"/*; do
  [ -f "$f" ] || continue
  name="$(basename -- "$f")"
  case "$name" in
    *.SIGNED-WITH-A-TEST-CERTIFICATE|*.stand-in-root.pem)
      echo "::error::$name: a stand-in signing artifact is staged for release" >&2
      bad=1 ;;
    *.pkg|*.msi)
      if grep -a -q -F -- "$marker" "$f"; then
        echo "::error::$name is signed with a stand-in (test) certificate ('$marker' in its signature); a stand-in-signed package is never published" >&2
        bad=1
      else
        echo "ok  $name carries no stand-in certificate"
      fi ;;
  esac
done
[ "$bad" -eq 0 ] || exit 1
echo "No stand-in-signed asset in $dir."
