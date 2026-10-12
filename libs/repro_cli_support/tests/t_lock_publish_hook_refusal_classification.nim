## D2 — the two pure functions the lock-publish failure diagnostic is composed
## from: which lines of a failed push transcript came from a hook, and what a
## quoted transcript may still contain.
##
## WHY THIS TEST EXISTS SEPARATELY FROM THE LIVE-GIT ONE.
##
## ``tests/integration/t_lock_publish_hook_refusal_is_not_read_as_connectivity``
## drives the whole path — real repositories, a real refusing ``pre-push``
## hook, a real push — and that is what proves the publisher reports a hook
## refusal as a hook refusal. But it can only ever exercise the ONE transcript
## the git on PATH produces from the ONE remote shape a local fixture can have:
## a ``file://`` path with no credential in it, refused locally. It therefore
## says nothing about a credential-bearing ``https`` remote, an ``ssh`` remote,
## a transcript carrying two URLs, or a transport failure that must NOT be read
## as a hook refusal.
##
## That gap is the same one ``t_lock_publish_push_race_classification`` beside
## this file was written for after the fact: a classifier over git's output was
## pinned only by whatever the maintainers' git emitted, and the case it got
## wrong shipped. Here the stakes are higher in one direction — these functions
## decide whether a CREDENTIAL reaches a gate report — so the forms are pinned
## directly.
##
## No mocks: both subjects are pure ``string -> …`` functions and the inputs are
## literal transcripts. The transport transcripts are the same captures the
## sibling file recorded from real git binaries.
##
## Falsifiable: widen the marker match to a bare ``repro`` and the transport
## cases below report refusal lines; drop the ``userinfo`` walk and the
## credential cases leak their token; redact the whole URL instead of its
## ``userinfo`` and the host/path assertions fail.

import std/[strutils, unittest]

import repro_cli_support

const
  secret = "ghp_EXAMPLESECRETTOKEN0000"

  # Real transport/policy transcripts, captured from git in the sibling
  # RA-29 test. None of them is a hook refusal in the sense this publisher
  # attributes, and none of them carries a credential.
  authFailure = "fatal: Authentication failed for " &
    "'http://127.0.0.1:35875/repo.git/'\n"
  missingRemote = """fatal: '/tmp/race/nope.git' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
"""
  unknownHost = "fatal: unable to access " &
    "'http://does-not-exist.invalid/repo.git/': Could not resolve host: " &
    "does-not-exist.invalid\n"
  preReceiveDeclined = """remote: error: pushes to this branch are not permitted
To /tmp/race/policy.git
 ! [remote rejected] HEAD -> main (pre-receive hook declined)
error: failed to push some refs to '/tmp/race/policy.git'
"""

suite "D2 lock-publish hook-refusal classification and URL redaction":

  test "a managed hook's own lines are the refusal, and nothing else is":
    # What the field failure looked like: the backend repo's own client-side
    # `pre-push` ran the gate, the gate refused, and git passed its stderr
    # through verbatim ahead of its own report.
    let transcript = """repro check: error: repo cairo has unpublished commits
repro hooks: refusal produced by /usr/bin/repro (resolved via PATH)
To /tmp/backend.git
 ! [remote rejected] HEAD -> main (pre-push hook declined)
error: failed to push some refs to '/tmp/backend.git'
"""
    let lines = pushOutputHookRefusalLines(transcript)
    check lines == @[
      "repro check: error: repo cairo has unpublished commits",
      "repro hooks: refusal produced by /usr/bin/repro (resolved via PATH)"]

  test "a marker behind git's remote: prefix is reported without the prefix":
    # receive-pack re-emits the other side's stderr behind `remote: `. The
    # refusal text is the part after the marker, so the prefix goes without a
    # second rule — and the line is not dropped for having one.
    check pushOutputHookRefusalLines(
      "remote: repro check: error: the record is not covered\n") ==
      @["repro check: error: the record is not covered"]

  test "real transport and policy failures report NO refusal lines":
    # THE assertion that keeps the connectivity/credentials wording reachable.
    # If any of these were read as a hook refusal, the one cause this publisher
    # genuinely cannot attribute would be reported as one it can.
    check pushOutputHookRefusalLines(authFailure).len == 0
    check pushOutputHookRefusalLines(missingRemote).len == 0
    check pushOutputHookRefusalLines(unknownHost).len == 0
    check pushOutputHookRefusalLines(preReceiveDeclined).len == 0
    check pushOutputHookRefusalLines("").len == 0
    # `repro` alone is not a marker: a remote whose path merely contains the
    # word must not turn a transport failure into a hook refusal.
    check pushOutputHookRefusalLines(
      "fatal: '/srv/repro/backend.git' does not appear to be a git " &
      "repository\n").len == 0

  test "URL userinfo is replaced and the backend coordinate survives":
    # The credential a forge's CI helper bakes into an https remote — the
    # exact form the withheld-transcript rationale was about.
    let quoted = "repro check: error: filed against " &
      "https://x-access-token:" & secret & "@forge.example.invalid/acme/m.git"
    let redacted = redactUrlUserinfo(quoted)
    check not redacted.contains(secret)
    check not redacted.contains("x-access-token")
    check redacted == "repro check: error: filed against https://" &
      urlUserinfoRedaction & "@forge.example.invalid/acme/m.git"

  test "every URL in the text is redacted, on every line":
    # A transcript is joined into one diagnostic field, so a redactor that
    # stopped at the first match or the first line would publish the rest.
    let text = "one https://u1:" & secret & "@a.invalid/x\n" &
      "two https://u2:" & secret & "@b.invalid/y and " &
      "https://u3:" & secret & "@c.invalid/z\n"
    let redacted = redactUrlUserinfo(text)
    check not redacted.contains(secret)
    check redacted.count(urlUserinfoRedaction) == 3
    check redacted.contains("@a.invalid/x")
    check redacted.contains("@b.invalid/y")
    check redacted.contains("@c.invalid/z")

  test "userinfo runs to the LAST @, and delimiters end the authority":
    # RFC 3986 permits percent-encoded bytes in userinfo, so a `%40` in the
    # password is not the delimiter; and a URL quoted inside punctuation must
    # not swallow the punctuation into its authority.
    check redactUrlUserinfo("https://user:p%40ss@host/p") ==
      "https://" & urlUserinfoRedaction & "@host/p"
    check redactUrlUserinfo("see <https://u:t@host/p>") ==
      "see <https://" & urlUserinfoRedaction & "@host/p>"
    check redactUrlUserinfo("'https://u:t@host'") ==
      "'https://" & urlUserinfoRedaction & "@host'"
    check redactUrlUserinfo("https://u:t@[::1]:8443/p") ==
      "https://" & urlUserinfoRedaction & "@[::1]:8443/p"
    # No path, no port, end of string: still redacted.
    check redactUrlUserinfo("https://u:t@host") ==
      "https://" & urlUserinfoRedaction & "@host"

  test "text with no credential is returned byte-for-byte":
    # The point of redacting the COMPONENT rather than dropping the stream is
    # that a transcript which never carried a secret is not damaged to protect
    # one. Every captured real transcript must survive intact.
    check redactUrlUserinfo(authFailure) == authFailure
    check redactUrlUserinfo(missingRemote) == missingRemote
    check redactUrlUserinfo(unknownHost) == unknownHost
    check redactUrlUserinfo(preReceiveDeclined) == preReceiveDeclined
    check redactUrlUserinfo("file:///tmp/race/origin.git") ==
      "file:///tmp/race/origin.git"
    check redactUrlUserinfo("no url here :// at all") ==
      "no url here :// at all"
    check redactUrlUserinfo("") == ""

  test "the scp-like SSH remote keeps its login name":
    # `git@host:path` has no scheme and its `git@` is a LOGIN NAME, not a
    # secret — the key never appears in the URL. Redacting it would delete a
    # host coordinate while protecting nothing.
    check redactUrlUserinfo("git@github.com:acme/manifests.git") ==
      "git@github.com:acme/manifests.git"
    # `ssh://` DOES have a scheme, so its userinfo goes the same way as any
    # other: the form is what is matched, not the scheme's name.
    check redactUrlUserinfo("ssh://git@host:22/acme/m.git") ==
      "ssh://" & urlUserinfoRedaction & "@host:22/acme/m.git"
