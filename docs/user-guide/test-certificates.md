# Test Certificates

A test certificate is a signed record saying that named tests passed on one
platform against one exact content of your repository. Reprobuild produces them
as a side effect of `repro test` and `repro certify`. Gates can then ask for them
at commit time, at push time and on the receiving side, and CI can use them to
skip work a developer already did.

Reprobuild implements the vendor-neutral
[test-certificate standard](https://github.com/metacraft-labs/test-certificates-spec).
Moving certificates around is the job of the
[`test_certificates`](https://github.com/metacraft-labs/test-certificates-tools)
library, which is linked into `repro`, so you install nothing extra.

> **Status:** ✓ Implemented and exercised on Linux. macOS and Windows run the same
> code but have not been exercised end to end.

## What a certificate binds to

A certificate names **content**, not a commit:

```toml
[certificate]
framework = "reprobuild"
project = "lib-a"
platform = "linux/amd64"
targets = ["t-unit"]
result = "passed"
key_id = "repro-daemon-key"

[certificate.vcs]
repo = "lib-a"
content = "git-tree-sha1:835c354b3619bc3fc9b8e4541a49a09bc71ba181"
untracked = false
base = "4734f637c986db0ca29a8708cbdd8b3dcec87fa0"
```

`content` is the id of the git tree that holds the tested files. A commit that
records that tree is covered, whichever commit it is. `base` is `HEAD` at issuance
and is only there for people reading the record: nothing compares it.

So the record says what was tested rather than where it sits in history:

| You do this | Coverage |
| ----------- | -------- |
| Commit exactly what you tested | Kept: the commit's tree is the certified content |
| Reword the message, or amend the author | Kept: the tree is unchanged |
| Stage only part of what you tested | Lost: the commit records different content |
| Add a file the tests never saw | Lost, for the same reason |
| Let a hook rewrite a tracked file during the commit | Lost, for the same reason |
| Rebase or cherry-pick onto a different base | Lost, unless the resulting tree happens to be identical |

`repro.lock` is a tracked file, so `content` binds it too. A gate reads the lock
out of the content it judges.

Each certificate carries an ed25519 signature. A verifier accepts it only when
`key_id` resolves to an active key in the registered-keys store,
`.repro/workspace/certificates/registered-keys.toml` in the workspace. The signing
key is `REPRO_DAEMON_SIGNING_KEY` when that is set, and otherwise `signing-key` in
the same directory, under the id `REPRO_DAEMON_KEY_ID` (default
`repro-daemon-key`). With no key, the tests still run and the certificate is
withheld:

```text
repro test: no certificate for 't-unit' — the daemon could not sign it (daemon signing key not found at '…'); the attestation is withheld
```

The key is currently a plain file readable by whoever runs the tests. Certificates
stop accidents such as a forgotten test run. They are not a defence against someone
who means to forge one.

## Certify, then commit

The order is: edit, test, commit.

```sh
$EDITOR src/parser.nim
repro certify            # or: repro test
git add -A
git commit -m "fix(parser): …"
```

The certifying run does not need a clean tree or a commit. Your uncommitted changes
are part of what it attests, and it prints the content id:

```text
repro test: issued test-certificate.v1 for 't-unit' on linux/amd64 for content git-tree-sha1:498f… (base 4374…) → <store path> (signed ed25519, key_id=…, 1 command(s))
```

The commit then needs no second run. Repeating the run on unchanged content does
nothing:

```text
repro test: re-certify is a no-op — the local certificate store (…) already covers [t-unit] for content git-tree-sha1:498f… on linux/amd64 (no relevant change; tests not re-run)
```

A certifying run first brings `repro.lock` and `flake.lock` up to date with the
sibling repositories, through a lock-update step that runs before the tests. The
tested content therefore already carries the refreshed locks, and the commit-time
lock refresh has nothing to do. The step prints each change as
`repro lock-update: …` and stages the locks it rewrote.

### Which run certifies what

A project names what it certifies in `repro.nim`, by marking a build-graph node:

```nim
build:
  let unit = testTool(actionId = "unit", ...)
  certificate "t-unit", aggregate("t-unit", @[unit])
```

| Command | What it certifies |
| ------- | ----------------- |
| `repro test` | What it selects, when that is a marked node. What a plain `repro test` runs is implicitly marked `certificate "test"` |
| `repro test --no-certify` | Nothing. The tests still run |
| `repro certify` | The names the policy rule for this branch requires, or every declared name when no rule applies |
| `repro certify <name>…` | The names given |
| `repro certify --check-set` | The repository's check set, under the name `pre-commit` |

`repro certificates list` prints what the project declares.

### When a certificate is withheld

The tests always run. Only the record is withheld, and the run ends with the
reason and the remedy:

| Reason | Remedy |
| ------ | ------ |
| A test failed | Fix it and run again |
| Tracked files changed while the tests ran | Leave them alone during the run, then run again |
| A sibling repository changed while the tests ran | The same, for the sibling |
| The state has no content id: an unmerged entry, an `assume-unchanged` flag, a present `skip-worktree` entry, or a submodule with modified content | Resolve the conflict, clear the flag, or commit inside the submodule. The message names the paths |
| The tests read an untracked file (`untracked_inputs = "read-set"`, the default) | `git add` it, or ignore it if it is generated or machine-local |
| Any untracked file exists (`untracked_inputs = "strict"`) | `git add`, ignore or delete each one |
| The lock-update step refused to move a pin backward | Bring the sibling forward, or name it in `REPRO_ALLOW_PIN_REGRESSION` |
| A sibling repository is dirty, unpublished or not at the revision the tested lock pins | Commit, push or check out that sibling |

Files that `.gitignore` covers are not untracked inputs: build outputs do not count.

## Adopting a policy

Nothing asks for a certificate until a repository enacts a policy. A policy is a
Nim constant, usually shared from a library package:

```nim
import repro_certificates

const teamPolicy* = certificatePolicy "team":
  rule "agents", "agents-to-dev-*":
    gateMode required
    commitGate advisory
    requires "t-unit", platforms = ["linux/amd64"]
```

The repository's `repro.nim` enacts it with `enactCertificatePolicy teamPolicy`,
and `repro lock refresh` records it in the `[certificate_policy]` section of
`repro.lock`:

```toml
[certificate_policy]
schema = "reprobuild.certificate-policy.v1"
name = "team"
package = "team-policy"
ci_trust = "advisory"
untracked_inputs = "read-set"

[[certificate_policy.rule]]
branches = ["agents", "agents-to-dev-*"]
gate_mode = "required"
commit_gate = "advisory"
requires = [{ certificate = "t-unit", platforms = ["linux/amd64"] }]
```

Gates read this section without running any Nim, from the content they judge. The
package's locked revision pins the policy. The first rule matching the branch wins,
and a branch no rule matches has no requirement.

- `gate_mode` is what a push is judged by: `off`, `advisory` or `required`.
- `commit_gate` is what the pre-commit gate does, and defaults to `gate_mode`.
- A malformed section refuses at every gate. It is never read as "no requirement".

`repro certificates policy` prints the policy and the rule for the current branch.
After changing the policy or moving its pin, run `repro lock refresh`; until then
`repro health` reports the snapshot as stale, and the next certifying run updates it
too. The refresh records the policy as it is now, even when an earlier build,
`repro certify` or `repro certificates` command evaluated the recipe before the change.
Run `repro hooks ensure --vcs` once after adopting a policy, to install the gate below.

## The pre-commit gate

`repro hooks ensure --vcs` installs a certificate gate in the managed `pre-commit`
hook of each repository whose `repro.lock` records a policy. It runs last, after
the lock refresh and any chained hook, so it judges the index that is really being
committed. It looks in the local store under that index's content id:

```text
repro pre-commit: certificate gate: no trusted certificate covers the content being committed (git-tree-sha1:…): linux/amd64 (missing: t-unit) (no certificate found in the local store under …; searched …)
repro pre-commit: certificate gate: unmet: 't-unit' on linux/amd64: run 'repro certify t-unit'
repro pre-commit: certificate gate: remedy: run 'repro certify' on exactly what you are committing (each name on each platform named above), then commit again
```

| `commit_gate` | Effect |
| ------------- | ------ |
| `required` | The commit is refused |
| `advisory` | The same report, and the commit proceeds |
| `off` | Nothing runs |

If the commit's own lock refresh re-pinned something, the report names that as the
cause, because the content being committed is then not the content that was tested.

This is early feedback, not enforcement. `git commit --no-verify` skips it, and the
push gates judge the pushed content again. It stands down during a rebase,
cherry-pick or `git am`, which re-create commits that already exist. When another
hook manager has displaced the dispatcher to `pre-commit.legacy`, it reports instead
of refusing, because that manager's hooks can still change the index afterwards.

## The local store

Every certificate is written to a per-user store outside any working tree. It has
two roots:

| Root | Location on Linux |
| ---- | ----------------- |
| User | `$TEST_CERTIFICATES_DIR`, else `$XDG_STATE_HOME/test-certificates`, else `~/.local/state/test-certificates` |
| System | `$TEST_CERTIFICATES_SYSTEM_DIR/<uid>`, else the standard's machine-wide directory |

[Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required)
gives the locations on other platforms. Both `repro health` and
`test-certificates store-root` print what resolves on your machine.

Records live at `v1/<algorithm>/<digest>/<payload hash>.toml`, keyed by content
only. A certificate issued from another clone or worktree of the same content
therefore counts here. The client gates search both roots and do not read notes.

The store is a cache, and losing it costs you a re-run. Each delivery prunes the
user root to the newest 20 content directories, always keeping the content of
`HEAD`, both unscoped and in every declared scope. Change the count with
`REPRO_CERTIFICATE_STORE_KEEP`, or with `keep = <n>` under `[certificate_store]` in
`$XDG_CONFIG_HOME/reprobuild/config.toml` (else `~/.config/reprobuild/config.toml`).

## How certificates reach a gateway

The local store does not leave your machine, and a gateway has no access to it.
Certificates travel as git notes on `refs/notes/test-certificates/certificates`,
**keyed by tree**, so one note serves every commit with that content. A gateway
finds them under `<pushed commit>^{tree}` and trusts only the signatures inside.

Reprobuild's tests and `repro certify` write only the store. The managed `pre-push`
hook does the carrying: on any `git push`, before the publication gate reports, it
publishes the store's certificates for the commits the push introduces and pushes
the notes ref to the same remote. You see one line:

```text
repro hooks: certificates: 1 certified tree(s) among 1 pushed commit(s): 1 certificate(s) added to refs/notes/test-certificates/certificates; pushed to origin
```

The notes go first, so they are already on the remote when a gateway judges the
branch. If the branch push is then refused, a later ordinary push of the same commit
still carries them.

The hook never fails your push, whatever goes wrong with the notes:

| Situation | What you see | What a gateway sees |
| --------- | ------------ | ------------------- |
| No certificate in the store for these commits | `no stored certificates …; nothing to propagate` | No note |
| The remote refuses the notes ref, or does not answer within the budget | `NOT fully propagated`, with the reason | Whatever arrived before it stopped |
| An invalid scope declaration | `invalid scope declaration: …`, then `NOT fully propagated` | No note |
| `TEST_CERTIFICATES_HOOK=off git push …` | `not propagated with this push` | No note |
| `git push --no-verify` | Nothing: every `pre-push` hook is skipped | No note |

### The hook's switches

- **`TEST_CERTIFICATES_HOOK`**: `off`, `0`, `false` or `no` skips propagation for
  the push. Set it on one command. If it stays exported, `repro health` warns.
- **`TEST_CERTIFICATES_HOOK_TIMEOUT`**: the time budget for all of the hook's network
  operations together, in whole seconds, at least 1. The default is 60. It cannot be
  switched off, so a stalled remote cannot hang your push. An invalid value is
  reported and ignored:

  ```text
  repro hooks: certificates: ignored TEST_CERTIFICATES_HOOK_TIMEOUT=abc (not a whole number of seconds, at least 1); using 60
  ```

- **`testCertificates.notesRef`** (git config): sends notes to another ref. Gateways
  read only the default, so `repro health` warns about any other value.

### Declared scopes

A certificate can cover part of a repository: its `vcs.paths` lists the paths, and
its content id is computed over only those. A repository says which scopes it uses
in git configuration, one section per scope and one literal path per value:

```ini
[testCertificatesScope "db"]
    path = Cargo.lock
    path = src/db-backend
```

The hook then also publishes notes for each pushed commit's scoped tree in each
scope, and pruning protects `HEAD`'s content in each scope. Paths are repo-relative
and `/`-separated. An invalid declaration stops propagation for the repository until
it is fixed, and `repro health` reports it. `repro test` and `repro certify` issue
whole-repository certificates; scoped ones come from other producers of the standard.

### When a push introduces nothing

The hook carries only what a push introduces: commits the remote does not have, as
far as your clone can tell. So a plain `git push` carries nothing in two cases:

- a certificate issued after its commit was published;
- a new branch at a commit a remote-tracking ref already reaches.

`repro push` carries both (see below). With plain git, carry them by hand:

```sh
test-certificates notes publish <commit>
test-certificates notes push <remote>
```

`test-certificates` is the executable of the same library, and `repro` does not
install it. To run it without installing anything, use
`nix run github:metacraft-labs/test-certificates-tools -- notes publish <commit>`.
On Windows, use `repro push`, which carries both cases.

## `repro push`

`repro push` certifies by content and then pushes. For each repository it publishes,
it judges the commits the push introduces, and the tip, against the policy in each
commit's own `repro.lock`, for the destination branch:

| Finding | What happens |
| ------- | ------------ |
| Covered | Nothing runs. After "certify, then commit" this is the normal case |
| Uncovered, and the commit's tree is the worktree's content | `repro certify <names>` runs for the names this host can produce, incrementally, and the report says `certified: t-unit` |
| Uncovered, and it is other content, under `required` | Refused before anything is published. The message names each commit, what it lacks and the remedy |
| The same, under `advisory` | Reported by name (five commits, then a count), and the push goes on |
| Lacks a name only another platform can produce | `required`: refused, naming the platform. `advisory`: reported |
| Coverage could not be evaluated | `required`: refused. `advisory`: reported |
| The policy section is malformed | Refused |

An older commit is judged only if no remote-tracking ref reaches it, so what a merge
of the mainline brought along is not treated as your branch's content.

A refusal looks like this, with exit code 2:

```text
repro push: lib-a (lib-a) → failed — commit cbcd4905b22f (v4) is not this checkout's content, and is not covered: linux/amd64 (missing: t-unit) (…)
    remedy: check cbcd4905b22f out and run 'repro test' (or 'repro certify t-unit' for exactly what it lacks), then retry 'repro push'; 'repro push --no-certify' leaves the decision to the pre-push and receiving gates
repro push: stopped repo=lib-a stage=certify-preflight
```

`advisory` reports the same commit and pushes:

```text
    certificates: commit be8b5ee9db3f lacks 't-unit' on linux/amd64: run 'repro certify t-unit' (…)
```

Under `required`, then, a branch with several untested commits has to be folded
together or certified commit by commit, which also applies after a
`--sync --rebase` rewrites them. Alternatively, certify the tip and use
`--no-certify`.

**`--no-certify`** means "obtain nothing": `repro push` runs no tests and judges no
commit, and the push goes to the `pre-push` and receiving gates. Those judge tips, so
an uncovered tip is still refused there under `required`. It does not hide what
exists: certificates already in the store still travel. To stop that as well, use
`TEST_CERTIFICATES_HOOK=off`.

After a certifying run the question is asked again rather than trusting the exit
code. A failing test stops the push with exit 2 under either mode. A run that changed
the worktree, such as a lock refresh, also stops it, and asks you to review and
commit the change. A run that passed but produced no certificate stops under
`required` and is reported under `advisory`.

`repro push` also carries what the hook would not: a repository reported as
`already-published`, and a new branch at a commit a remote-tracking ref already
reaches, the latter before the branch push:

```text
repro push: lib-a (lib-a) → already-published
    repro hooks: certificates: 1 certificate(s) for 774fa92f…: pushed to origin
```

So a certificate issued after publishing reaches the remote with one more
`repro push`. The `notes publish` then `notes push` remedy appears in its output only
for what the library could not carry.

## Earlier-draft certificates

Records from before the standard moved to content binding are bound to a commit:
they carry `vcs.commit` and `clean`, and have no `content`. No current verifier
accepts them, and they are never translated, because translating would attest a
content id that no run computed. A gate that meets one rejects it and tells you to
re-issue it by re-running the tests.

Reprobuild neither searches for nor deletes such records. If your workspace holds
some, in `.repro/workspace/certificates/` or on
`refs/notes/reprobuild/certificates`, remove them by hand. `registered-keys.toml`
and `signing-key` in that directory are the key store, so leave them.

## Checking it with `repro health`

The `certificate-propagation` row of `repro health` is the one line to read:

```text
store roots: user /home/you/.local/state/test-certificates, system …/1000;
reference library test_certificates 0.1.0 linked;
carrier switched: this build writes no notes, the pre-push hook carries them;
lib-a: pre-push hook installed;
policy 'team' from team-policy pinned at 7818debb…;
branch 'main': certificate policy 'team' rule "**" (matched by "**"): required, requires t-unit (linux/amd64);
snapshot current;
scope declarations and notes ref valid in 12 repo(s)
```

The part about one repository describes the repository you run it from, when that is
inside the workspace. `--json` carries the same facts under `data`. The row warns
about an invalid scope declaration, a `testCertificates.notesRef` other than the
default, `TEST_CERTIFICATES_HOOK` left off, a store with no root it can resolve, and
a stale snapshot in the current repository.

Related rows: `certificate-policy` gives the rule for each repository's checked-out
branch, `certificate-policy-snapshot` reports staleness across the workspace,
`vcs-hooks` reports hooks missing anywhere, and `push-gateway` says whether a push
reaches a gateway at all.

## Troubleshooting

**The commit is refused, though I just tested.** The index differs from what you
tested. Compare the id in the refusal with the one the run printed. The usual causes
are a partial stage, an unadded file, and a hook that rewrote something. Stage
everything you tested, or run `repro certify` again on what you mean to commit.

**The refusal blames a re-pin.** A sibling moved after your run, so the commit's lock
refresh changed `repro.lock`. Run `repro certify` again with the refreshed lock
staged.

**`no certificate … has no content id`.** The message names the paths. For example,
`git update-index --no-assume-unchanged -- <path>` clears the flag it reports.

**`key_id '…' not registered`.** The verifier could not find the signing key in the
registered-keys store of the workspace it used. For `repro ci plan` in a workspace,
pass `--workspace-root=<workspace>` and `--current-repo=<path to the repository>`, or the
repository is taken for the workspace and its own store is read.

**A gateway refuses with "no certificate note on the pushed tree".** Nothing
propagated a note, for one of two reasons, and the refusal ends by saying the pushed
commit's content must be the content that was tested. The commit may not record it:
after a partial stage or a hook that rewrote a file, no certificate exists for its
content and there is nothing to carry. Compare its tree, `git rev-parse <commit>^{tree}`,
with the id the run printed, and if they differ, run `repro test` on that commit. If
they match, the certificate exists and did not travel, so certifying again will not
help. Check whether the push used `--no-verify` or `TEST_CERTIFICATES_HOOK=off`, read
the `repro hooks: certificates:` lines, and if the commit was already on the remote, use
`repro push` or the two `notes` commands above.

**`NOT fully propagated`.** The line above it gives the reason: a refused notes ref, a
stalled remote, or an invalid scope. The push went through. Fix the cause, and a later
push of new commits, or `repro push`, carries the rest.

**A push prints no `repro hooks: certificates:` line.** Two explanations. The push
introduced nothing, so the hook had nothing to say; see
[When a push introduces nothing](#when-a-push-introduces-nothing). Or the push did
introduce commits and the `repro` servicing the hook is a build from before
propagation, which answers the same hook contract, carries nothing and reports
nothing. The line `repro hooks: pre-push above was produced by …` names that build;
compare it with the `repro` you expect.

**The row says `pre-push hook MISSING`.** Run `repro hooks ensure --vcs`. Without the
hook a plain `git push` carries no notes.

## Further reading

- [The standard](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Standard.md),
  with [content ids](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Content-Id.md),
  [transport](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md)
  and [tooling](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md)
- [Workspace Locking](workspace-locking.md), for the publication gate these hooks
  share and for recovering from a refused push
