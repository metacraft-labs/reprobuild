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

The design rationale behind it is written up in
`Unified-Locking-And-Hooks.md`, in Reprobuild's non-public specification
repository. The parts you need in order to use locking are reproduced
here; `repro locking explain` reports the resolved tier and backend for
every repo, and which configuration layer decided it.

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

### The managed hooks do not run in a linked worktree

A **relative** `core.hooksPath` — typically `.git/hooks`, which the
`git-hooks.nix` installer writes — is resolved by Git against the top level
of whichever worktree is running the hook. In a linked worktree (`git worktree
add`, `repro branch`) `.git` is a *file*, so that path names nothing and Git
runs **no hooks at all** there: commits and pushes from the worktree bypass the
publication gate without a word.

Reprobuild reports it in three places. A commit or checkout in the repository
prints a `repro hooks: core.hooksPath in <repo> is the relative path …`
diagnosis and leaves the value alone (it is your git config, and you did not
run a hooks command). A `pre-push` from the main worktree rewrites the value,
or refuses the push when it cannot. And `repro health` reports the repository
as `PATH-UNSAFE` in its `vcs-hooks` row, after any `STALE` hooks and before any
shadowed or missing ones. The repair rewrites the value to the absolute path it
was meant to name, which every worktree then shares:

```console
$ repro hooks ensure --vcs <repo-or-workspace>    # or: repro health --fix
```

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
| Committed lock | `repro.lock` at a repo root, schema `reprobuild.solved-graph-lock.v3` (v2 still read), solved from a recipe's solver inputs | `repro lock refresh [<path>]` |
| Workspace lock | `locks/<project>/<repo>/<sha>.toml` inside a tier's backend (a git-checkout manifest store, an external DB, …) | `repro workspace lock [<project>] [--workspace-root=PATH]` |

`repro lock refresh` needs solver inputs. Run at a workspace root that
has none it answers `no solver inputs found for <path> (expected a
compiled repro.lock-adjacent recipe, a repro.solver sidecar, or pass
--inputs <file>)` and exits 1 — so it is never the answer to a
team/personal backend record.

`repro lock refresh` re-observes each sibling from its checkout, but it
**never moves a committed pin backward silently**. When a sibling's
checkout is behind the revision the lock already pins, has diverged from
it, or lacks the pinned commit, the refresh writes nothing and exits 4,
naming the sibling, both commits, the checkout and the command that
brings it forward (`git -C <sibling> merge --ff-only …`, `repro ws sync
<project>`, or a fetch). A deliberate downgrade, or a move onto another
line of the sibling's history, is spelled out:
`repro lock refresh <path> --allow-pin-regression=<sibling>[,<sibling>…]`
(or `REPRO_ALLOW_PIN_REGRESSION=<sibling>`, the same variable the
`pre-commit` re-pin honors). Each pin's `ref` is a published branch that
contains the pinned commit (`agents` first, then `dev`, then the
checkout's branch, the remote's default, or any other published branch
containing it) and is empty when no published branch contains it; a
local-only branch name is never recorded.

`repro lock refresh` also **refuses to write a lock from an incomplete
solve**. A recipe's `uses:` pulls sibling recipes into the solve
transitively; when a `uses:` names a develop-set sibling (one the
workspace manifest's `depends` declare, even when the project containing
it is not enabled in this workspace, or one the committed lock already
pins) whose recipe the refresh cannot read — the sibling is
not checked out, or is checked out where `uses:` discovery does not find
it — that recipe's version constraints would be missing from the solve,
and the lock would pin versions the next build in a complete workspace
refuses. The refresh then writes nothing, exits 5, and names the sibling,
the recipe whose `uses:` reaches it, and where it was expected. Check the
sibling out (`repro sync`, or `repro ws enable` the project that declares
it) and refresh again. A sibling checked out without any recipe declares
no constraints and is not a reason to refuse. `repro lock solve` without
`--write` prints the same finding as a warning.

#### `ELockConflict`: re-pin one package, not the whole lock

A committed lock is a pin, so a build refuses with `ELockConflict` when
the recipe now declares a range the lock's version does not satisfy. The
usual cause is a **new** constraint: a `uses:` line added to the project,
or a sibling it consumes, after the lock was written. A sibling consumed
as a pure-Nim-source library counts: this project's compiler compiles
its modules, so its toolchain floor (`nim >=2.2 <3.0`) binds this lock.
When the declaring package belongs to such a sibling, the diagnostic
says it is a **cross-repo producer**, so look for the constraint in that
repo's recipe, not in yours.

The first remedy the diagnostic names is the targeted re-pin:

```
repro lock refresh --repin=<package>[,<package>…]
```

It re-solves only the named packages and holds every other entry. The
solve runs with every other committed package version and variant value
supplied as a hard pin, the same pins a build applies. The written lock
differs from the committed one only in the named packages' `packages`
entries, plus **added** entries for packages the lock did not record yet
(a newly declared producer's own package, for example). It never changes
or removes another entry. Sibling revision pins (`deps`) already in the
lock, provisioning records and the certificate-policy snapshot are carried
forward; a sibling the lock does not pin yet (the newly declared producer
itself) is added at the revision the solve saw. The one
`deps` entry it rewrites is the repo's own (marked `self = "true"`), which records
the tree the lock was solved from.

- When another held pin **also** contradicts a declared range, the
  re-pin fails with that pin's `ELockConflict` and writes nothing. Add
  that package to `--repin` and run it again. The flag never re-solves a
  package you did not name.
- It needs a committed lock and package names the solve actually has.
  If either is missing it exits 2 and writes nothing.
- The incomplete-solve refusal (exit 5) and the pin-regression gate
  (exit 4) apply as they do to a full refresh.

A full `repro lock refresh` (every version pin and every sibling
revision pin re-solved) and relaxing the declared constraint are still
available. Use them when that is the change you want.

`repro workspace lock` resolves a bare invocation against the **current
directory**, with no upward search. The gate speaks from inside the
pushed repo, so its remedies spell out `--workspace-root=` and can be
pasted as printed.

### An intended upgrade: `repro lock update`

```
repro lock update <dependency> [--to <rev>] [--repo-root=<dir>]
                  [--allow-pin-regression=<name>[,<name>…]]
```

A recipe states a **constraint** and a lock records a **resolution**: a
`repro.nim` `uses:` range or exact version against a `repro.lock` entry,
a `flake.nix` input URL (a branch, or an exact `rev=<sha>` /
`github:o/r/<sha>`) against a `flake.lock` node. The managed `pre-commit`
hook re-pins resolutions from your sibling checkouts on every commit, but
it **never rewrites a constraint**: when an exact pin (or a range) excludes
the revision a sibling is at, it refuses the commit and names this
command, because only you know whether the newer checkout is an upgrade or
an experiment. A `repro test` or `repro certify` run that issues a test
certificate refreshes both locks before its tests with the same writers and
the same rules; where the hook would refuse the commit, that run writes
nothing and issues no certificate, and its tests still run.

`repro lock update` is that upgrade, in one step and for both systems:

- **The dependency** may be named by its `flake.nix` input name, its
  `repro.lock` dependency name or its workspace repo name. All of them must
  mean one repository, identified by canonical URL (`github:o/r`,
  `git+https://github.com/o/r` and `https://github.com/o/r.git` are one
  repository). A name that means two repositories is refused with every
  candidate; name one as `input:<name>`, `dep:<name>` or `repo:<name>`.
- **The target** is `--to <rev>` (a commit id, or a ref resolved in the
  sibling checkout); else the sibling checkout's `HEAD`; else, for a flake
  input that follows a branch, the tip nix resolves. A `repro.lock`
  dependency entry with no checkout needs `--to`: the entry records a
  checkout's revision, and the solver selects package versions, never a
  dependency's revision.
- **Every resolution moves**: each `flake.lock` root input and each
  `repro.lock` dependency entry of that repository.
- **An exact pin that excludes the target is rewritten** in whichever recipe
  states it. In `flake.nix` the revision in the input's URL changes and
  nothing else in the file does; the node is then re-locked through nix
  (`nix flake update <input>`), which is what computes its new `narHash`. In
  `repro.nim` an exact `uses:` version is replaced by the version whose
  producer `versions:` entry maps to the target; if none does, the command
  refuses (exit 3) and asks you to add that entry.
- **A pin you removed is finished for you.** To switch a `flake.nix` input
  from an exact revision to a branch, remove the revision from its URL and
  run this command. nix keeps the removed revision in the node's
  `original.rev` until it re-locks the node, so the command re-locks it
  through nix (`nix flake update <input>`) and then moves it to the target
  like any branch-following input, under the same rules below.
- **A `uses:` range is never rewritten.** One that admits the target is left
  alone; one that excludes it is refused (exit 3), naming the line, because
  widening a range is the author's decision.
- **A pin never moves backward silently**: a target behind, or diverged
  from, a current resolution is refused (exit 4) unless
  `--allow-pin-regression=<name>` or `REPRO_ALLOW_PIN_REGRESSION=<name>`
  names the dependency (any of its names).
- **A pin names published content.** A target that exists only in the
  sibling checkout (reachable from no remote-tracking ref, judged locally,
  never over the network) is refused (exit 1) when a `flake.lock`
  resolution would name it, because nix cannot fetch it for anyone else;
  the message names the `git push` that publishes it. A move of
  `repro.lock` alone is written with a warning, and the push gate refuses
  the push until the target is published.
- **A modified checkout is not its `HEAD`.** When the target defaults to the
  sibling's `HEAD` and that checkout has uncommitted changes, the command
  refuses (exit 1); commit or stash them, or name the commit with `--to`.
- **All or nothing.** If anything fails — nix is missing or cannot fetch
  the target, a rewrite does not land, the result would not pass the
  recipe/lock consistency checks — every file is put back byte for byte
  (exit 1). The result is left in the working tree; nothing is staged or
  committed.

When the target is not what the sibling checkout is at, the command says
so: unless a recipe pins the dependency exactly, the next commit's re-pin
records whatever is checked out, so check the sibling out at the target
before committing.

`repro flake refresh-lock --only=<names>` does the same for each input it
names, with the sibling's `HEAD` as the target (`--record-downgrade` allows
a target behind the current pin). Without an explicit
`--only`, `refresh-lock` keeps refreshing only the branch-following inputs
and declines an exact pin.

### A temporary experiment: develop overrides and exact pins

```
repro develop --only=<dependency>     # substitute one dependency, pinned or not
repro develop --all                   # substitute the lock set, exact pins excepted
repro develop --drop=<dependency> [--workspace-root=<dir>] [--project-root=<dir>]
```

Debugging against a sibling checkout uses a develop override, which never
writes a recipe or a lock. How it meets an exact recipe pin depends on how
the dependency was selected:

- **A bulk selection skips an exact pin.** `repro develop --all` (and every
  other mode or pattern selection) does not substitute a dependency whose
  `flake.nix` pins a revision (`rev=<sha>`, `github:o/r/<sha>`) or whose
  `repro.nim` pins an exact `uses:` version. It records no override for it
  and lists it as `pinned by recipe at <file>:<line>`; so do `--dry-run`,
  `--list` (state `pinned`) and their `--json` forms. The flake override
  verb's automatic mode (`repro flake override-args --all`, which
  `useFlakeDevShell` runs at shell entry) leaves such an input on its
  `flake.lock` pin in the same way. A pin means "this revision, not whatever
  is checked out", and building against the checkout anyway would quietly
  build something the recipe disclaims. The managed hooks do not compare a
  skipped pin with its checkout, so a sibling that has moved on neither
  re-pins nor refuses a commit.
- **An explicit selection substitutes it.** `repro develop --only=<dependency>`
  does, and so does `repro flake override-args --only=<dependency>` or an
  explicit `overrideInputs` entry of `useFlakeDevShell`. This is how a pinned
  dependency is debugged. Once the checkout moves past the pin, the next
  commit is refused (H3), so the experiment is not published by accident.
- **Dropping the override ends the experiment.** `repro develop
  --drop=<dependency>` removes that dependency's override from the
  workspace's `.repro/develop-overrides.toml` and from the per-project
  override documents (`repro develop <dependency> --into`) of the workspace
  root and of `--project-root` (default: the project you are in). It matches
  an entry by the dependency's name or by its checkout, as the hooks do. It
  touches no checkout and no lock, and naming a dependency with no override
  is a reported no-op. The H3 refusal prints this command, with the right
  roots, as its "temporary experiment" remedy.

Which kind of selection recorded an override is kept in its `provenance`:
`repro develop --only=<dependency>` for an explicit one, `repro develop --all`
for a bulk one. **Overrides recorded before this distinction existed count
as bulk**, because `--all` and `--only` both wrote `repro develop --all`
then and the two cannot be told apart; so does an entry with no provenance.
After upgrading, an exact pin under such an entry is therefore not
substituted: the hooks do not compare it with its checkout, the flake override
verbs leave it on its pin, `repro build` resolves it from the lock rather
than the checkout (and says so once, naming the two commands below), and
`--list` shows it `pinned` and names the ignored entry. An explicit entry
still substitutes it in `repro build`, and an override of a dependency that is
not exactly pinned is followed exactly as before, whatever its provenance. To
keep substituting it, run `repro develop --only=<dependency>` again, which
records the explicit provenance; to clear it, run `repro develop
--drop=<dependency>`.

### Exact pins of workspace siblings: guidance, never a refusal

An exact revision in a recipe is legitimate, so no rule refuses one. But a
repository you develop side by side as a workspace sibling is usually better
tracked through the lock: the recipe names it on a branch (or a range), and the
commit-time re-pin moves the lock as you work. Reprobuild says so in two
places, and neither changes whether anything is refused or the exit status:

- **In refusals.** An H1, H2 or H3 refusal about an exact pin of a repository
  that has a sibling checkout adds one `Guidance:` line naming the sibling and
  the conversion: replace the exact revision with a branch reference (a range
  in `repro.nim`), then run the printed `repro lock update <dependency>`. That
  one command finishes the job for a `flake.nix` input too: a `flake.lock`
  node that still records the removed revision (`original.rev`) is re-locked
  through nix from `flake.nix` before it is moved.
- **In `repro check` and `repro health`.** Every exact recipe pin of a
  workspace sibling, in `flake.nix` and in `repro.nim`, is listed as an
  informational finding with its file and line, and with the comment written
  beside the pin, or `no reason stated` when there is none. `repro check`
  prints each as a `repro check: info:` line and in the `findings` array of
  its JSON report; `repro health` lists them in its `sibling-exact-pins` row,
  which is always `ok`. Write the reason next to a pin you mean to keep.

Both point to "your organisation's dependency guidelines". Set
`REPRO_DEPENDENCY_GUIDELINES_URL` to make them name your guidelines' address
instead.

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
  `.repro/build/reports/post-commit-lock.log` and
  `.repro/build/reports/post-commit-report.json` — says what became of the
  record:

  | Outcome | Meaning |
  |---|---|
  | `published` | The record is present in the lock store's last-known upstream. The only success. |
  | `written-pending-publish` | Written to a publishable store; not upstream yet. The normal state between a commit and a push — pre-push publishes it. |
  | `written-local-only` | Written, but the store is not publishable (not its own checkout, or no upstream). The record will not leave this machine. |
  | `written-publication-unknown` | Written; the publication check itself failed. Treat as unpublished. |
  | `no-manifest-record` | The lock writer succeeded but wrote no manifest record — records are routed per-repo, or the workspace is public-only and carries its lock in the in-repo `repro.lock`. |
  | `no-lock-dirty-siblings` | **No lock exists.** An in-scope repo has uncommitted changes; a lock recorded over them would not reproduce the tree it claims. Commit or stash them and run `repro workspace lock`. |
  | `no-lock-failed` | **No lock exists.** The lock writer failed; the diagnostic names the reason (commonly a declared repo with no checkout). A triggering checkout that no project declares lands here too: there is no repo name to key a record on, so a record somebody would have looked for cannot be written. |
  | `skipped-membership-repo` | **No lock is due.** The commit landed in the workspace's membership repo — the checkout carrying `projects/` and `repos/`, which no project declares as one of its repos. It is not a project repo, so it has no name to encode as the `<repo>` component of `locks/<project>/<repo>/<sha>.toml` and belongs to no tier's partition; a membership commit therefore anchors no trigger-keyed record at all. Nothing failed and nothing is pending. The repos whose pins the commit changes each record their own lock when they are pushed. Logged, with no stderr warning: this is a designed steady state, and a warning on every manifest commit teaches you to stop reading them. |
  | `skipped-no-workspace` | Not a workspace; the hook does not apply here. **Reported on stderr only** — see below. |
  | `skipped-git-operation-in-progress` | Git was mid-rebase / mid-cherry-pick / mid-bisect in the repo that fired the hook. The commit the hook saw is one of that operation's intermediate commits, so nothing was written into the working tree and no ref was pushed. The diagnostic names the marker that proved it. The pre-push gate refreshes the lock before anything is published, so no lock is lost. |
  | `inert-git-state-unknown` | The hook could not determine whether a git operation was in progress (git unresolvable, or the repo path is not a checkout). It did nothing and said so on stderr — "I could not tell" is not the same answer as "nothing is happening". |

  The report also carries `pendingRecords` (unpublished records for the
  trigger repo in the store) and `strandedRecords` — those pending
  records whose trigger commit has **already been pushed**. A stranded
  record means a push went out without its lock, so publication is not
  merely pending: it is not running. Any stranded record, any refusal,
  and any writer failure also prints a line to stderr, which git shows
  you at the terminal. The commit still succeeds in every case.

  That stderr line is easy to miss, so `repro health` reads the log for
  you. Its `lock-writer` row sorts the outcomes above into *wrote*
  (`published`, `written-*`), *refused* (`no-lock-dirty-siblings`,
  `no-lock-failed`) and *no record due* (`no-manifest-record`, the
  `skipped-*` outcomes and `inert-git-state-unknown`, which change
  nothing), and counts the refusals since the last written record.
  `no-manifest-record` is not a refusal: the record lives elsewhere, in
  the in-repo `repro.lock` of a public-only workspace or in a per-repo
  route. One refusal is a `warn`; two or more in a row are a `fail`. The
  row lists every distinct refusal reason in that run, newest first,
  because fixing the reason on the last line can leave an older one
  standing. A log that exists but cannot be read is a `warn` naming the
  error. The row reads only the last 4 MiB of the log and never changes
  anything: after fixing the reason, run `repro workspace lock` to confirm
  the writer succeeds.

  **`skipped-no-workspace` has no report file, by design.** When the hook
  decides the root is not a workspace, it writes nothing at all and says so
  on stderr instead. There is no workspace to own a `.repro/build/reports/`
  tree, so the report used to be filed at the nearest `.repro/` shell at or
  above the committing repo — inside a repo the engine had just disclaimed.
  Two things were wrong with that and only one of them is about tidiness.
  The files are untracked content in a git checkout: the dirt the lock
  publisher refuses on, regenerated by the hook its own next commit fires.
  And nothing reads them — no command may read a report back to decide
  anything, and a report inside a repo nothing considers a workspace has no
  reader by construction. Its sibling gate already rules this way: `repro
  check --mode=pre-push` answers a non-workspace with one stderr line and
  exit 0, writing no artifact. If you see this line, the managed hooks are
  installed somewhere they have nothing to do: finish the bootstrap (`repro
  workspace init`) or remove them.

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
- [Reading your config: `repro locking explain`](#reading-your-config-repro-locking-explain) —
  the resolved tier and backend for every repo, and the configuration
  layer that decided it.
- `repro hooks ensure --vcs <repo-or-workspace>` — installing and
  repairing the VCS hooks.
- `repro push` — outgoing-HEAD handling, lock recovery, and partial
  publication semantics, described above.

The design specs behind this page (`Unified-Locking-And-Hooks.md`,
`CLI/hooks.md`, `CLI/push-hook-publication-protocol.md`) live in
Reprobuild's non-public specification repository.

## Restore a project set in a fresh directory

`repro ws restore` checks out a selected project union at the exact commits in
a workspace lock or named snapshot:

```sh
repro ws restore ../workspace ../restored --projects=compiler,tools \
  --record=/path/to/record.toml
repro ws restore https://example.com/org/workspace.git ../release \
  --at=<metadata-commit> --projects=compiler,tools --snapshot=release
```

A local source uses its committed metadata `HEAD`; `--at` selects another
metadata revision and is required for URL sources. Uncommitted source changes
are ignored. Relative record paths resolve from the invoking directory.
Alternatively, `--record=project/repo@<full-commit>` reads the exact record from
a separate record store. Local sources discover `.repro/records` (with the
legacy `.repro/manifests` fallback); `--record-store=PATH|URL` selects one
explicitly. Automatic discovery covers only those conventional local locations;
configured Git stores elsewhere require `--record-store`. Read its committed
`HEAD` or `--record-store-at=REV`; URL stores
require the revision flag. The resolved store commit is reported and retained
at `<destination>/.repro/records`.

Every selected Git repository must have a matching full commit pin. Checkouts
are detached, the active project selection is recorded, and output lists the
verified commit for each checkout. Other VCS members are refused. The
source workspace is preserved. Use an absent or empty destination outside the
local source workspace and input repositories, with an existing parent directory. Failed restores
remove staging and preserve an initially empty destination.
