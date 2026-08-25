# Workspace Locking: Public, Team, and Personal Tiers

When your workspace has more than one repository, reprobuild records the
exact revision of each one in a **lock**, so that you (and your
teammates) can reproduce the same workspace later or on another machine.
This page is the task-oriented guide to setting locking up: choosing a
scheme, wiring a team or personal tier, reading your resolved config,
and recovering when a push is refused.

If you only ever build a single public repository, you do **not** need
this page — locking works out of the box (see
[Choosing a scheme](#choosing-a-scheme) below). Come back when you add a
private team repo or a personal side-repo to the mix.

For the full design rationale, see
[Unified-Locking-And-Hooks.md](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/Unified-Locking-And-Hooks.md)
in `reprobuild-specs/`.

## The mental model: tiers and backends

Every repo in a workspace resolves to exactly one **tier**:

- **public** — anyone who clones the repo can see it.
- **team** — shared within your team/company, but not public.
- **personal** — only you use it (a side-repo, a scratch fork).

Each tier's lock lives in its own **durable backend**:

| Tier | Where its lock lives | Who can read it |
|---|---|---|
| public | the in-repo committed `repro.lock`, pushed with your code | anyone who clones the repo, including the git server |
| team | a shared private manifests repo (or any configured backend) | teammates with access to that backend |
| personal | a private manifests repo **you** create and push to | only you |

### The tier-isolation guarantee, in plain terms

**A repo's revision (its SHA) never crosses a visibility boundary.** A
personal repo's SHA never lands in a team backend; a team repo's SHA
never lands in the public `repro.lock`. This is *structural*, not a
matter of discipline: a repo's tier is decided by **which configuration
layer names it**, and the public layer simply never names a private
repo — so the public `repro.lock` *cannot* reference one. You get the
guarantee for free by declaring each private repo in the right
configuration layer.

## Choosing a scheme

Pick the smallest scheme that fits your workspace.

### Public-only (the default — nothing to configure)

A workspace of public repos needs **no configuration at all**. Each
repo's public dependencies are pinned in its own committed `repro.lock`,
which is committed and pushed with the code. This is the only tier a
config-free workspace has, and it is what every public repo gets for
free.

If that describes you, stop here.

### Add a team tier

Choose this when some repos in the workspace are shared within your
team/company but must not appear in a public lock. You point the **team
tier** at a shared backend — typically a private manifests repo. Two
equivalent ways to declare it are described in
[The team-tier workflow](#the-team-tier-workflow).

### Add a personal tier

Choose this when you have a repo only *you* use and want its revisions
pinned and restorable across your own machines, without exposing it to
teammates. You point the **personal tier** at a private manifests repo
you own. See [The personal-tier workflow](#the-personal-tier-workflow).

You can mix all three in one workspace — see the
[worked example](#worked-example-a-mixed-workspace) at the end.

## The configuration form

All locking configuration is authored in a `reprobuild.config.v1` TOML
file. Routes and `apply_if` bindings are authored as **inline-table
arrays** — `route = [{ ... }]` and `apply_if = [{ ... }]`. Do **not**
use the `[[double-bracket]]` array-of-tables form; the pinned TOML
parser rejects it for these nested arrays.

A `[locking] route` entry maps a tier to the backend that holds that
tier's lock:

```toml
schema = "reprobuild.config.v1"

[locking]
route = [
  { visibility = "team", backend = "git-checkout", path = ".repo/manifests-team", repos = ["acme-internal", "acme-shared"] },
]
```

- `visibility` — the tier: `public` | `team` (or `org`) | `personal`
  (`private` is accepted as a synonym for personal).
- `backend` — one of `committed-file`, `git-checkout`, `git-notes`,
  `separate-branch`, `external-cli`.
- `path` — the backend location (for `git-checkout`, the manifests-repo
  root; relative paths resolve against the workspace root).
- `program` — the program for an `external-cli` backend.
- `repos` — the repos this route governs, named by repo name or path.
  **Because a route names them, those repos belong to this route's
  tier** — this is the tier-by-layer rule that makes tier isolation
  structural.

### Where config files live (the layers)

Configuration composes from layers, in increasing precedence:

1. **Built-in default** — every public repo, public tier, committed
   `repro.lock`. No file.
2. **System config** (IT-maintained) — `/etc/reprobuild/config.toml`
   (override with `REPROBUILD_SYSTEM_CONFIG`; `%PROGRAMDATA%\reprobuild\config.toml`
   on Windows).
3. **User dotfiles** — `~/.config/reprobuild/config.toml` (override with
   `REPROBUILD_USER_CONFIG`).
4. **Parent workspace repo** — a `.repro-workspace.toml` `[locking]`
   table in a shared `repro-workspace` repo.
5. **VCS-private local metadata** — `<git-common-dir>/repro/config.toml`
   (override with `REPROBUILD_VCS_PRIVATE_CONFIG`). Never tracked, never
   pushed — like `.git/config` or `.git/info/exclude`.

A repo's tier is an **output** of composing these layers, not a field
stamped on the repo. Layers naming different repos union; a
higher-precedence layer may refine the *backend* for a repo within the
same tier; but moving a repo *across* tiers between layers is a loud
error (it would break tier isolation).

### The `apply_if` directive

`apply_if` is a path-scoped binding — "for any workspace checked out
under folder X, apply this configuration." It is modeled directly on
Git's conditional includes (`[includeIf "gitdir:~/work/"]`). This is how
the system and dotfiles layers scope their routes to the right
workspaces:

```toml
schema = "reprobuild.config.v1"

apply_if = [{ under = "~/work/acme/", config = "team-routes.toml" }]
```

`under` matches as a normalized path-prefix: the workspace activates the
binding when its path equals `under` or is nested under it. The
referenced `config` file contributes its `[locking] route` entries.
"Team via IT system config" and "personal via dotfiles" are the **same
mechanism at different scopes** — a system `apply_if` under a broad org
path versus a user `apply_if` under a personal-projects path.

## The team-tier workflow

There are two first-class ways to obtain a team tier. Pick whichever
fits how your team already works.

### Form A — a parent `repro-workspace` repo

If your team already shares a workspace repo (the star topology),
declare the team routes in its `.repro-workspace.toml` (layer 4):

```toml
# .repro-workspace.toml (committed in the shared repro-workspace repo)
[locking]
route = [
  { visibility = "team", backend = "git-checkout", path = ".repo/manifests-team", repos = ["acme-internal", "acme-shared"] },
]
```

Every teammate who checks out the workspace inherits the team route.
The team repos' locks are written as `locks/<project>/<repo>/<sha>.toml`
into the shared `git-checkout` backend and pushed on a passing
`repro push`.

### Form B — IT/system `apply_if` (team without a workspace repo)

If your team does **not** want a shared workspace repo, IT ships the
route through the system config layer instead. On each managed machine,
`/etc/reprobuild/config.toml` (layer 2) carries an `apply_if` scoped to
the org's projects path:

```toml
# /etc/reprobuild/config.toml (IT-maintained, on every managed machine)
schema = "reprobuild.config.v1"
apply_if = [{ under = "/work/acme/", config = "/etc/reprobuild/acme-team-routes.toml" }]
```

```toml
# /etc/reprobuild/acme-team-routes.toml
schema = "reprobuild.config.v1"
[locking]
route = [
  { visibility = "team", backend = "git-checkout", path = "/srv/acme/manifests-team", repos = ["acme-internal"] },
]
```

Any workspace checked out under `/work/acme/` now has a team tier — with
**no workspace repo at all**. This is a fully supported shape.

## The personal-tier workflow

The personal tier is designed so that once your dotfiles are set up, a
personal repo's participation restores on any of your machines with **no
per-repo manual step**.

**Step 1 — create a private manifests repo** you own and can push to
(e.g. a private git repo on your own account). This is the durable
backend where your personal locks live.

**Step 2 — declare a personal route** in a config file, pointing at that
backend:

```toml
# ~/dotfiles/reprobuild/personal-routes.toml
schema = "reprobuild.config.v1"
[locking]
route = [
  { visibility = "personal", backend = "git-checkout", path = "~/.repro/personal-manifests", repos = ["my-scratch-fork"] },
]
```

**Step 3 — bind it via a dotfiles `apply_if`** in your user config
(layer 3), scoped to where you keep personal projects:

```toml
# ~/.config/reprobuild/config.toml
schema = "reprobuild.config.v1"
apply_if = [{ under = "~/projects/", config = "~/dotfiles/reprobuild/personal-routes.toml" }]
```

**Step 4 — sync your dotfiles, and everything else is automatic.** Any
workspace under `~/projects/` that contains `my-scratch-fork` now pins
it to your personal backend. On a passing `repro push`, the personal
lock is written to your private manifests repo.

### Restoring a workspace on a new machine

This is the capability the two-plane design exists to deliver. On a
fresh machine:

1. **Sync your dotfiles** (which carry the personal route from step 3).
2. Clone the workspace and run `repro sync`.

Reprobuild reads the **configuration** from your synced dotfiles (the
`apply_if` route) and the **lock data** from your pushed private
manifests repo, and reconstructs the workspace **at the locked
revisions** — not the latest branch tip. No per-repo manual step is
needed: the config plane comes from dotfiles, the durable lock comes
from the pushed backend, and the two together restore the exact state.

If you skip the dotfiles sync (no route) *or* never pushed the lock (no
durable data), the repo falls back to its branch tip instead of the
locked revision — both halves are load-bearing.

## Reading your config: `repro locking explain`

To see how each repo in the current workspace resolved — its tier, its
backend, and **which configuration layer declared it** — run:

```console
$ repro locking explain
repro locking explain — resolved (tier, backend) per repo:
  acme-app (apps/acme-app): tier=public backend=committed-lock layer=built-in default
  acme-internal (libs/acme-internal): tier=team backend=git-checkout layer=parent-workspace-repo [.repro-workspace.toml]
  my-scratch-fork (vendor/my-scratch-fork): tier=personal backend=git-checkout layer=dotfiles [~/dotfiles/reprobuild/personal-routes.toml]
```

Add `--json` for the machine-readable `reprobuild.locking-explain.v1`
form (one `{repo, path, tier, backend, layer, source}` object per repo).

Use this whenever a repo isn't landing in the tier you expect: the
`layer` column tells you which file to edit.

## Recovering from a refused push

`repro push` runs the client `pre-push` gate. Most refusals name the
offending repo, its tier, its backend, and a copy-pasteable next step.
Here is what each one means.

### Refreshing hooks after a protocol mismatch

The generated dispatcher, managed hook body, and `repro` CLI use hook
protocol v2 as one executable contract. If any one of them is older or only a
partial hook refresh landed, publication fails closed before the first source
repository is pushed. Refresh the complete hook pair and retry:

```console
$ repro hooks ensure --vcs <repo-or-workspace>
$ repro push --sync --rebase
```

Run the same `hooks ensure` command for a separately checked-out lock backend
named by the diagnostic. The command preserves existing user hooks; preserved
hooks run without Reprobuild's internal capability or legacy recursion marker
in their environment.

### The hook does not recognize the `repro` it found

A managed hook runs `$REPROBUILD_REPRO`, or whatever `repro` is on `PATH`. If
that binary is not the build the hook was generated by, the hook says so and
stops rather than letting an unidentified build speak for it:

```console
repro hooks: pre-push: the resolved 'repro' does not speak this hook's contract.
repro hooks:   resolved binary: /nix/store/…-reprobuild-0.1.3/bin/repro (resolved from PATH)
repro hooks:   hook contract:   reprobuild.managed-hook.v1.pre-push.…
```

This is worth reading closely, because the alternative is worse: an outdated
build that cannot read your current manifests refuses the push with a
diagnostic about *your files* — a TOML parse error in a file that parses
fine — and you spend the afternoon on the wrong suspect. `pre-push` refuses; a
commit hook prints the same block and still exits 0, because a hook has no
business failing a commit after the fact.

Two ways out. Point the hooks at the binary you mean:

```console
$ REPROBUILD_REPRO=/path/to/current/repro git push
```

or reinstall the hooks from it, so hook and CLI match again:

```console
$ /path/to/current/repro hooks ensure --vcs <repo-or-workspace>
```

Relatedly, when a dispatch *does* run and fails, the hook names the binary that
produced the failure and where it came from. If a refusal surprises you, check
that line first.

### A dependency is unpublished

A raw `git push` may publish the current repository's exact clean `HEAD` when
Git proposes one well-formed fast-forward branch update to the configured
remote. It does not make an unpublished dependency publishable. Use
`repro push` to publish the dependency closure in dependency-first order:

```console
$ repro push --sync --rebase
```

Unrelated repositories outside that closure do not block the operation.

### A source push succeeded but a later step failed

`repro push` is resumable, not all-or-nothing. If a later repository or lock
backend refuses the operation, earlier source commits remain published. The
text and JSON reports name the stopped repository/stage, retain the successfully
published prefix, show any verified local-only lock-backend `HEAD`, and provide
the retry command. Fix the named cause and run that command; Reprobuild treats
the published prefix as no-ops and continues in dependency order.

If the report says an expected lock record was never created, a retry alone
does not synthesize it. Run the exact `repro workspace lock ...` command in the
report and then retry `repro push`. If a prior attempt committed a valid
lock-only chain locally but failed to push it, retry verifies every commit and
record before resuming an ordinary fast-forward backend push. Dirty, divergent,
or non-lock history is left untouched for manual inspection.

### `lock-backend-unreachable` (team or public backend down)

> `team repo 'acme-internal' could not be published to its git-checkout
> backend at .repo/manifests-team (push rejected: no upstream); make the
> backend reachable and re-run \`repro push\``

Your push touched a repo whose **team** (or public) backend could not be
written. Teammates depend on that backend, so the push is **refused
(exit 2)**. Remedy: make the backend reachable (fix the remote, restore
network, grant access), then re-run `repro push`.

### Personal backend unreachable — a WARNING, not a refusal

> `personal lock backend git-checkout at ~/.repro/personal-manifests is
> unreachable; personal repo 'my-scratch-fork' participation was not
> recorded — run \`repro workspace lock --workspace-root=<root>\` when it
> is reachable`

Your **personal** backend was unreachable. Because it is *your own*
backend and only you depend on it, this is a **warning — the push still
succeeds (exit 0)**. Your personal participation just wasn't recorded
this time; run `repro workspace lock` once the backend is reachable to
re-pin it. It never blocks your push to a public or team repo.

### Which lock verb? `repro workspace lock` vs `repro lock refresh`

Reprobuild has **two** lock artifacts, and they are not interchangeable.
A refusal names the verb for the artifact it is about; run the other one
and it will fail no matter how often you retry.

| Artifact | What it is | Re-pin it with |
|---|---|---|
| Committed lock | `repro.lock` at a repo root, schema `reprobuild.solved-graph-lock.v2`, solved from a recipe's solver inputs | `repro lock refresh [<path>]` |
| Workspace lock | `locks/<project>/<repo>/<sha>.toml` inside a tier's backend (a git-checkout manifest store, an external DB, …) | `repro workspace lock [<project>] [--workspace-root=PATH]` |

`repro lock refresh` needs solver inputs. Run at a workspace root that
has none it answers `no solver inputs found for <path> (expected a
compiled repro.lock-adjacent recipe, a repro.solver sidecar, or pass
--inputs <file>)` and exits 1 — so it is never the answer to a
team/personal backend record.

`repro workspace lock` resolves a bare invocation against the **current
directory**, with no upward search. The gate speaks from inside the
pushed repo, so its remedies spell out `--workspace-root=` and can be
pasted as printed.

### `locked-integrity-mismatch` (a lock that no longer verifies)

This **refuses (exit 2)** for every tier, including personal (a
corruption is not a mere unreachable backend). The diagnostic names the
tier, the backend, and a machine-readable `cause=` in its evidence.
There are two distinct causes and they are not repaired the same way.

**`cause=locked-revision-unreachable` — the revision is gone.**

> `the locked revision 8f0786b5… for '<repo>' is not present in the
> checkout, so the locked record cannot be verified (tier=team
> backend=git-checkout location=…). A force-push or history rewrite
> upstream is the usual cause — the revision is GONE, not changed.
> Restore it in the team backend, or re-pin at the current revision with
> \`repro workspace lock --workspace-root=<root>\``

Nothing was tampered with: the commit the lock pins no longer exists in
the checkout. Either restore it in the backend (push it back from a
clone that still has it), or accept the new history and re-pin.

**`cause=content-mismatch` — the content changed under a revision that
is still there.**

> `the content at the locked coordinates no longer matches the recorded
> integrity for '<repo>' (tier=team backend=git-checkout location=…);
> restore the locked revision in the team backend or run \`repro
> workspace lock --workspace-root=<root>\` to re-pin`

The record or the materialized content was rewritten after it was
locked. Investigate before re-pinning — this is the shape a tamper
takes.

A **public / committed-lock** entry reports the same two causes, but its
remedy names `repro lock refresh` because the committed `repro.lock` is
the artifact that failed.

### `lock_references_private_repo` (private repo in the public lock)

> `the pushed public repro.lock references the private-only repo
> '<repo>' (visibility=personal); a public-only clone cannot reproduce
> it — remove it from the public lock or publish it under a non-public
> tier's backend`

The committed `repro.lock` you tried to push references a private-only
repo. A public-only clone could never reproduce it, so it is refused —
and the **server-side `pre-receive` gate refuses it too** (see
[The hook boundary](#the-hook-boundary)). Remedy: give the private repo
a proper team/personal route so it lands in that tier's backend instead
of the public lock.

### `lock-failure` on an unrouted private repo

> `no locking backend configured for personal repo '<repo>': a personal
> repo's participation cannot be recorded in the public committed lock.
> Add a \`[locking] route\` entry with visibility="personal" (e.g.
> backend="git-checkout" or backend="external-cli") to a configuration
> layer …`

A private (non-public) repo in the pushed closure is not named by any
route in any configuration layer, so reprobuild refuses to silently drop
it into the public lock. Remedy: add a `[locking] route` (or an
`apply_if`-referenced routes file) naming the repo under the right tier —
then re-run `repro locking explain` to confirm it resolved.

## Migrating a legacy `.repo/manifests` workspace

If your workspace already has a `.repo/manifests` checkout but no
explicit team route, reprobuild will **not** silently drop its team
lock. It warns once:

> `repro: WARNING — this workspace has a \`.repo/manifests\` checkout but
> NO team route declared in any configuration layer.`
> `To keep \`.repo/manifests\` as the TEAM backend, run:  repro locking
> adopt-manifest --workspace-root=<path>`

Run the scaffold to keep the manifest as your team backend:

```console
$ repro locking adopt-manifest
repro locking adopt-manifest: wrote team route for 4 repo(s) → git-checkout at `.repo/manifests`
  config layer (VCS-private, never pushed): <git-common-dir>/repro/config.toml
  run `repro locking explain` to verify the resolved (tier, backend) for each repo.
```

This writes a team `[locking] route` for the existing manifest into the
**VCS-private config layer** (layer 5, never pushed), so your workspace
keeps `.repo/manifests` as its team backend instead of going public-only.
Verify with `repro locking explain`.

## The hook boundary

Three VCS hooks participate in locking. Knowing what each does — and
what it can and cannot see — is what makes the refusal messages above
make sense.

- **post-commit** (local only, never blocks the commit) — best-effort
  refreshes each repo's lock record in its tier's backend *locally*
  (never over the network) and fires the async shared-cache push. For an
  evidence-only repo it publishes only a source-free evidence triple and
  is excluded from the cache push (its source objects are never
  propagated). Any failure is logged; the commit always succeeds.

  Because post-commit cannot publish, it never reports a bare success for
  writing a record. Its outcome — in
  `.repro/workspace/post-commit-lock.log` and
  `.repro/workspace/post-commit-report.json` — says what became of the
  record:

  | Outcome | Meaning |
  |---|---|
  | `published` | The record is present in the lock store's last-known upstream. The only success. |
  | `written-pending-publish` | Written to a publishable store; not upstream yet. The normal state between a commit and a push — pre-push publishes it. |
  | `written-local-only` | Written, but the store is not publishable (not its own checkout, or no upstream). The record will not leave this machine. |
  | `written-publication-unknown` | Written; the publication check itself failed. Treat as unpublished. |
  | `no-manifest-record` | The lock writer succeeded but wrote no manifest record — records are routed per-repo, or the workspace is public-only and carries its lock in the in-repo `repro.lock`. |
  | `no-lock-dirty-siblings` | **No lock exists.** An in-scope repo has uncommitted changes; a lock recorded over them would not reproduce the tree it claims. Commit or stash them and run `repro workspace lock`. |
  | `no-lock-failed` | **No lock exists.** The lock writer failed; the diagnostic names the reason (commonly a declared repo with no checkout). |
  | `skipped-no-workspace` | Not a workspace; the hook does not apply here. |
  | `skipped-git-operation-in-progress` | Git was mid-rebase / mid-cherry-pick / mid-bisect in the repo that fired the hook. The commit the hook saw is one of that operation's intermediate commits, so nothing was written into the working tree and no ref was pushed. The diagnostic names the marker that proved it. The pre-push gate refreshes the lock before anything is published, so no lock is lost. |
  | `inert-git-state-unknown` | The hook could not determine whether a git operation was in progress (git unresolvable, or the repo path is not a checkout). It did nothing and said so on stderr — "I could not tell" is not the same answer as "nothing is happening". |

  The report also carries `pendingRecords` (unpublished records for the
  trigger repo in the store) and `strandedRecords` — those pending
  records whose trigger commit has **already been pushed**. A stranded
  record means a push went out without its lock, so publication is not
  merely pending: it is not running. Any stranded record, any refusal,
  and any writer failure also prints a line to stderr, which git shows
  you at the terminal. The commit still succeeds in every case.

- **pre-push** (client gate; `--no-verify` bypasses it) — the currency +
  publication check for the whole publication boundary. It reads each
  in-scope repo's locked SHA from **its own tier's backend**, verifies
  integrity, and publishes each tier's records to its backend. A public
  or team backend that is unreachable **refuses** the push; a personal
  one **warns and allows** (see
  [Recovering from a refused push](#recovering-from-a-refused-push)).

- **pre-receive** (server gate; `--no-verify`-proof) — runs on the bare
  receiving repo, so `git push --no-verify` cannot bypass it. **It gates
  the public tier only.** It rejects a push whose committed `repro.lock`
  references a private-only repo (`lock_references_private_repo`) or
  whose received lock fails its integrity recompute
  (`locked-integrity-mismatch`), and it verifies test certificates. It
  makes **no claim** about the team, personal, or evidence backends —
  the server cannot read them. Their reproducibility is enforced entirely
  by the client `pre-push` gate and by each backend's own access control.

## Worked example: a mixed workspace

A single workspace with one public app, one team library, and one
personal fork. The public repo needs no config. The team route lives in
the shared workspace repo; the personal route comes from your dotfiles.

```toml
# .repro-workspace.toml (committed in the shared repro-workspace repo)
schema = "reprobuild.config.v1"
[locking]
route = [
  { visibility = "team", backend = "git-checkout", path = ".repo/manifests-team", repos = ["acme-internal"] },
]
```

```toml
# ~/.config/reprobuild/config.toml (your dotfiles, layer 3)
schema = "reprobuild.config.v1"
apply_if = [{ under = "~/work/acme/", config = "~/dotfiles/reprobuild/personal-routes.toml" }]
```

```toml
# ~/dotfiles/reprobuild/personal-routes.toml
schema = "reprobuild.config.v1"
[locking]
route = [
  { visibility = "personal", backend = "git-checkout", path = "~/.repro/personal-manifests", repos = ["my-scratch-fork"] },
]
```

`repro locking explain` for a workspace checked out under
`~/work/acme/`:

```console
$ repro locking explain
repro locking explain — resolved (tier, backend) per repo:
  acme-app (apps/acme-app): tier=public backend=committed-lock layer=built-in default
  acme-internal (libs/acme-internal): tier=team backend=git-checkout layer=parent-workspace-repo [.repro-workspace.toml]
  my-scratch-fork (vendor/my-scratch-fork): tier=personal backend=git-checkout layer=dotfiles [~/dotfiles/reprobuild/personal-routes.toml]
```

On `repro push`: `acme-app`'s pins go into the committed `repro.lock`
pushed with the repo; `acme-internal`'s SHA goes into the team
manifests-team backend; `my-scratch-fork`'s SHA goes into your personal
manifests repo — **each record in its own backend, and no other**. If
your personal backend is offline you still push successfully (with a
warning); if the team backend is offline the push is refused until you
fix it.

## Related documentation

- [Reprobuild docs home](../README.md).
- [Unified-Locking-And-Hooks.md](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/Unified-Locking-And-Hooks.md) —
  the design spec behind this page.
- [`repro hooks`](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/CLI/hooks.md) —
  installing and managing the VCS hooks.
- [`repro push` and pre-push publication protocol](https://github.com/metacraft-labs/reprobuild-specs/blob/latest/CLI/push-hook-publication-protocol.md) —
  strict outgoing-HEAD handling, hook protocol v2, lock recovery, and partial
  publication semantics.
