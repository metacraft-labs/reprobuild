## RA-29 — ``pushOutputIsNonFastForward`` classifies LITERAL captured git
## push transcripts, not whatever wording the local git happens to emit.
##
## Why this test exists: the classifier used to require ``cannot lock ref``
## as a conjunct of the compare-and-swap clause. git 2.50.1 emits that detail
## line, git 2.51.2 does not — it collapses the whole race into
## ``! [remote rejected] HEAD -> main (incorrect old value provided)``. So on
## a 2.51 host every lost lock-publication race was classified as a hard
## failure, the bounded re-apply loop was never entered, and the user saw a
## spurious "check backend connectivity, credentials, and branch policy" on a
## perfectly healthy remote. The live-git integration suite
## (``tests/integration/t_concurrent_lock_publishes_retry_*``,
## ``t_concurrent_publish_disjoint_per_backend``,
## ``t_lock_publish_recovers_verified_ahead_chain``) could not catch it: it
## only ever exercises the ONE wording produced by the git on PATH, so it
## passed on the maintainers' 2.50.1 and failed only in CI.
##
## Every transcript below was captured by reproducing the real failure against
## a real git binary in a scratch repository — a mid-push race via a
## ``pre-push`` hook that pushes a disjoint commit from a second clone after
## git has advertised the old remote tip but before receive-pack updates the
## ref (positive cases), and real transport / credential / branch-policy
## failures (negative cases). They are pinned line-for-line so a future
## wording change fails HERE instead of silently disabling the retry path. The
## only edit applied to the capture is dropping the trailing blank padding git
## appends to ``remote:`` sideband lines (the classifier substring-matches, so
## trailing spaces cannot affect it) and rewriting the fixture's temporary
## directory to a stable ``/tmp/race`` path.
##
## No mocks: the subject is a pure ``string -> bool`` predicate and the inputs
## are recorded output of the real tool. The transcripts stand in for the git
## versions we cannot all have installed at once, which is exactly the
## coverage a live-git test cannot provide.
##
## Falsifiable: restore ``cannot lock ref`` as a required conjunct and the
## git-2.51.2 case fails; drop the rejection-marker requirement and the
## authentication / unresolvable-host cases fail; drop the policy discriminator
## and the ``pre-receive hook declined`` case fails.

import std/unittest

import repro_cli_support

const
  # git 2.50.1: `git -C <work> push origin HEAD:main`, remote advanced by a
  # pre-push hook after advertisement. The compare-and-swap loss is reported
  # on a `remote: error:` detail line; the reason parenthetical is the generic
  # `(failed to update ref)`.
  Git2501RaceTranscript = """remote: error: cannot lock ref 'refs/heads/main': is at 1ee7a21823cf6fd52195aa144b19b141b09de166 but expected 8ae27140436e4b68668f1400585c218d27969c04
To /tmp/race/origin.git
 ! [remote rejected] HEAD -> main (failed to update ref)
error: failed to push some refs to '/tmp/race/origin.git'
"""

  # git 2.51.2: the SAME race, same command, same fixture. The `cannot lock
  # ref` detail line is gone entirely and the compare-and-swap loss survives
  # only as the reason parenthetical.
  Git2512RaceTranscript = """To /tmp/race/origin.git
 ! [remote rejected] HEAD -> main (incorrect old value provided)
error: failed to push some refs to '/tmp/race/origin.git'
"""

  # Client-side detection: the remote was already ahead when git advertised
  # it, so git rejects locally without contacting receive-pack. Byte-identical
  # on 2.50.1 and 2.51.2. Still a "the remote tip moved" rejection, so it
  # enters the same recovery loop — which then refuses unless the previously
  # observed tip is provably still an ancestor of the freshly fetched one.
  GitFetchFirstTranscript = """To /tmp/race/div.git
 ! [rejected]        HEAD -> main (fetch first)
error: failed to push some refs to '/tmp/race/div.git'
hint: Updates were rejected because the remote contains work that you do not
hint: have locally. This is usually caused by another repository pushing to
hint: the same ref. If you want to integrate the remote changes, use
hint: 'git pull' before pushing again.
hint: See the 'Note about fast-forwards' in 'git push --help' for details.
"""

  # HTTP 401 from the remote. Byte-identical on 2.50.1 and 2.51.2.
  GitAuthFailureTranscript = """fatal: Authentication failed for 'http://127.0.0.1:35875/repo.git/'
"""

  # Remote path that is not a repository. Byte-identical on 2.50.1 and 2.51.2.
  GitMissingRemoteTranscript = """fatal: '/tmp/race/nope.git' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
"""

  # Unresolvable host. Byte-identical on 2.50.1 and 2.51.2.
  GitUnknownHostTranscript = """fatal: unable to access 'http://does-not-exist.invalid/repo.git/': Could not resolve host: does-not-exist.invalid
"""

  # Branch policy: a `pre-receive` hook refused the update. This one DOES
  # carry a `[remote rejected]` marker, so the rejection marker alone can
  # never be sufficient — the classifier must additionally require evidence
  # that the ref's VALUE or LOCK was the problem. Byte-identical on 2.50.1
  # and 2.51.2.
  GitHookDeclinedTranscript = """remote: error: pushes to this branch are not permitted
To /tmp/race/policy.git
 ! [remote rejected] HEAD -> main (pre-receive hook declined)
error: failed to push some refs to '/tmp/race/policy.git'
"""

suite "RA-29 lock-publish push-race classification":
  test "captured mid-push race transcripts are retryable on every git version":
    check pushOutputIsNonFastForward(Git2501RaceTranscript)
    check pushOutputIsNonFastForward(Git2512RaceTranscript)

  test "git 2.51 wording alone is sufficient evidence of a lost race":
    # The narrowest possible statement of the shipped bug: the ONLY line git
    # 2.51.2 gives us about the race, with no surrounding context at all.
    check pushOutputIsNonFastForward(
      " ! [remote rejected] HEAD -> main (incorrect old value provided)\n")
    # ...and no single phrase of the older wording may be load-bearing.
    check pushOutputIsNonFastForward(
      " ! [remote rejected] HEAD -> main (failed to update ref)\n")

  test "client-side non-fast-forward rejection is retryable":
    check pushOutputIsNonFastForward(GitFetchFirstTranscript)

  test "both rejection spellings are recognised":
    # `[rejected]` (client-side) and `[remote rejected]` (receive-pack) are
    # BOTH live and neither is a substring of the other, so matching only one
    # of them silently drops half the failure modes.
    check pushOutputIsNonFastForward(
      " ! [rejected]        HEAD -> main (non-fast-forward)\n")
    check pushOutputIsNonFastForward(
      " ! [remote rejected] HEAD -> main (incorrect old value provided)\n")

  test "transport and credential failures stay hard failures":
    check not pushOutputIsNonFastForward(GitAuthFailureTranscript)
    check not pushOutputIsNonFastForward(GitMissingRemoteTranscript)
    check not pushOutputIsNonFastForward(GitUnknownHostTranscript)

  test "branch-policy refusal stays a hard failure":
    check not pushOutputIsNonFastForward(GitHookDeclinedTranscript)

  test "a successful push is never a race":
    check not pushOutputIsNonFastForward("")
    check not pushOutputIsNonFastForward(
      "To /tmp/race/origin.git\n   8ae2714..1ee7a21  HEAD -> main\n")
