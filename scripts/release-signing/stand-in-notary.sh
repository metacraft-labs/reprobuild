#!/bin/sh
# A STAND-IN for Apple's notary service, answering as `xcrun notarytool` and
# `xcrun stapler` do, for runs that sign with stand-in certificates.
#
#   stand-in-notary.sh notarytool submit <file> [notarytool options...]
#   stand-in-notary.sh notarytool log <submission-id> [options...]
#   stand-in-notary.sh stapler staple|validate <file>
#
# ## Why a stand-in exists at all
#
# Apple notarizes only packages signed with a Developer ID certificate that
# Apple issued; a package signed with a stand-in certificate is refused by the
# real service whatever the credentials. So until the production certificate
# and the notarization credentials are configured, the notarization step of
# the release leg (scripts/release/build_signed_installer.sh) runs against
# this script instead: that exercises everything on our side of the service
# -- the command line we build, the credentials we pass, how we read the
# answer, that an `Invalid` answer fails the leg, and the stapling call --
# and nothing on Apple's side. What it cannot show (that Apple accepts the
# package, that the ticket staples, that Gatekeeper then accepts it) is only
# shown by a run with the production certificate and credentials.
#
# It is chosen by configuration, never by code: the leg uses it when
# REPRO_NOTARYTOOL / REPRO_STAPLER name it, which the stand-in mode does by
# default and the production mode never does. Every answer it prints carries
# `"standIn": true`, which real notarytool never prints, and the production
# mode refuses an answer that carries it.
#
# ## What it answers
#
# `submit`: notarytool's JSON form (`--output-format json`,
#   https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
#   `{"id": ..., "message": ..., "status": ...}`, with the status taken from
#   REPRO_STANDIN_NOTARY_ANSWER (`Accepted`, the default, or `Invalid`). It
#   exits 0 for both, so the caller must judge by the status, as it must for
#   the real tool's JSON. A missing or empty <file> is refused (exit 1), as
#   the service refuses an upload it cannot read.
# `log`: a JSON log naming the submission, with an issue when the answer is
#   `Invalid`.
# `stapler staple|validate`: prints stapler's success line and exits 0; it
#   does not modify the file (there is no ticket to attach).
#
# Each call is appended, one line per call with its arguments, to
# REPRO_STANDIN_NOTARY_LOG when that is set, so a test can assert what the
# leg asked for. The values of `--key`, `--key-id`, `--issuer`, `--password`
# and `--apple-id` are recorded as `<redacted>`: the log must never hold a
# credential, even a throwaway one.

set -eu

record() {
  [ -n "${REPRO_STANDIN_NOTARY_LOG:-}" ] || return 0
  _line=''
  _redact=0
  for _a in "$@"; do
    if [ "$_redact" -eq 1 ]; then _a='<redacted>'; _redact=0; fi
    case "$_a" in
      --key|--key-id|--issuer|--password|--apple-id) _redact=1 ;;
    esac
    _line="$_line $_a"
  done
  printf '%s\n' "${_line# }" >> "$REPRO_STANDIN_NOTARY_LOG"
}

die() { printf 'stand-in-notary: %s\n' "$*" >&2; exit 1; }

record "$@"
tool="${1:-}"; [ $# -gt 0 ] && shift
verb="${1:-}"; [ $# -gt 0 ] && shift
answer="${REPRO_STANDIN_NOTARY_ANSWER:-Accepted}"
case "$answer" in
  Accepted|Invalid) ;;
  *) die "REPRO_STANDIN_NOTARY_ANSWER must be Accepted or Invalid, not '$answer'" ;;
esac
# A fixed submission id: the stand-in has no queue, and a test can match it.
id='00000000-0000-4000-8000-000000000000'

case "$tool:$verb" in
  notarytool:submit)
    file="${1:-}"
    [ -n "$file" ] && [ -s "$file" ] || die "submit: no such file or empty: '$file'"
    if [ "$answer" = Accepted ]; then msg='Processing complete'; else msg='Processing complete with issues'; fi
    printf '{"id":"%s","message":"%s","status":"%s","standIn":true}\n' "$id" "$msg" "$answer"
    ;;
  notarytool:log)
    if [ "$answer" = Accepted ]; then
      printf '{"jobId":"%s","status":"Accepted","statusSummary":"Ready for distribution","issues":null,"standIn":true}\n' "$id"
    else
      printf '{"jobId":"%s","status":"Invalid","statusSummary":"Archive contains critical validation errors","issues":[{"severity":"error","message":"The stand-in notary was told to refuse this submission (REPRO_STANDIN_NOTARY_ANSWER=Invalid)."}],"standIn":true}\n' "$id"
    fi
    ;;
  stapler:staple|stapler:validate)
    file="${1:-}"
    [ -n "$file" ] && [ -s "$file" ] || die "$verb: no such file or empty: '$file'"
    printf 'Processing: %s\nThe %s action worked! (stand-in: no ticket was attached)\n' "$file" "$verb"
    ;;
  *)
    die "unsupported call: $tool $verb (supported: notarytool submit|log, stapler staple|validate)"
    ;;
esac
