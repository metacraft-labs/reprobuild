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
[Unified-Locking-And-Hooks.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Unified-Locking-And-Hooks.md)
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
> recorded — run \`repro lock refresh\` when it is reachable`

Your **personal** backend was unreachable. Because it is *your own*
backend and only you depend on it, this is a **warning — the push still
succeeds (exit 0)**. Your personal participation just wasn't recorded
this time; run `repro lock refresh` once the backend is reachable to
re-pin it. It never blocks your push to a public or team repo.

### `locked-integrity-mismatch` (a tampered or corrupt lock)

> `the content at the locked coordinates no longer matches the recorded
> integrity for '<repo>' (tier=team backend=git-checkout); restore the
> locked revision in the team backend or run \`repro lock refresh\` to
> re-pin`

A locked entry's recorded integrity no longer matches the content at its
coordinates — the locked revision is missing/unreachable, or the record
was tampered with. This **refuses (exit 2)** for every tier, including
personal (a corruption is not a mere unreachable backend). The
diagnostic names the tier and backend. Remedy: restore the locked
revision in that backend, or run `repro lock refresh` to re-pin to the
current state.

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
- [Unified-Locking-And-Hooks.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Unified-Locking-And-Hooks.md) —
  the design spec behind this page.
- [`repro hooks`](https://github.com/metacraft-labs/reprobuild-specs/blob/main/CLI/hooks.md) —
  installing and managing the VCS hooks.
