# Reprobuild for Experienced Developers & AI Agents

Reprobuild is a unified build, dependency, environment, and workspace tool.

## Architecture & Grepable Keywords

Reprobuild models the workspace as a directed acyclic graph (DAG) of type-checked actions defined in the **`repro.nim`** DSL. Sibling repositories declared as **`repos/*.toml`** fragments in the workspace root (whose policy lives in **`repro-workspace.toml`**) are routed dynamically using **`repro develop`** (develop-mode). Build hermeticity is enforced using the **`librepro_monitor_shim`** user-space filesystem interceptor, and execution is cached locally through a per-edge disk store fronted by a host-wide **shared-memory grow-only index** that every engine inserts into directly. Package toolchains are concretized using a **`clingo`** solver, and background services are orchestrated using **`servicePlaceholder`** declarations.

## Non-Interactive CLI Execution for Agents

When invoking `repro` from an automated tool call (with no interactive TTY):

- **Run commands inside the project environment with `repro exec -- <cmd> [args...]`** — never invoke `repro shell`, which opens an interactive subshell and blocks non-TTY callers.
- **Request structured output with `--json`** (or `--format=json` on `capabilities`): `repro version --json`, `repro health --json [--offline]`, `repro graph --json`, `repro why <target> --json`, `repro show-conventions --json`, `repro stats overview --json`, `repro pressure --json`.
- **Preview host or account changes before applying**: run `repro infra plan` before `repro infra apply --plan <id>`, and `repro home plan` before `repro home apply`.
- **Never hand-edit generated lock or scan files**: update `repro.lock` with `repro lock update [<dep>]` or `repro lock refresh`, and update `repro.scanned-deps.nim` with `repro deps refresh`.

## `repro` Is Two Binaries, Plus the Engine's Graph Helper

`repro` on `PATH` is a ~520 KB **thin daemon client**
(`apps/repro-client/repro_client.nim`). It hands a routable `repro build` to
the already-running per-user daemon and `execv`s the ~17 MB **engine**,
installed beside it as **`reprobuild`** (`apps/repro/repro.nim`), for
everything else — every other verb, and every build it cannot route.

A third image, **`reprobuild-helper`** (`apps/reprobuild-helper`), sits
beside the engine and is never typed by a user. The build graph runs its own
helper commands with it: `internal compile-provider`, `extract-interface`,
`compile-profile`, `probe-profile-platforms`, `dev-env-introspect`,
`render-dev-env-shell` and `cmake-regenerate` (also spelt
`__repro-<role>`). It is built from the same sources and dispatches through
the same parser as the engine, but **without `-d:ssl`**. Those helpers run
inside monitored actions, so whatever their process does at start-up is
evidence for the action; with `-d:ssl` the OpenSSL libraries load at start-up
and, on Windows, read entropy while they do, which kept every such action
from being cached on its first run. The engine keeps TLS for its https cache
and deploy paths.

Practical consequences when you are working in this repo:

- `just build` / `scripts/build_apps.sh` produce `build/bin/repro`,
  `build/bin/reprobuild` **and** `build/bin/reprobuild-helper`. A tree
  without all three is not a working tree; `scripts/bootstrap_guard.sh`
  checks for them.
- Keep them **siblings**. `siblingTryCompileProviderPath` /
  `siblingStandardProviderPath` resolve the Tier-2a/2b provider binaries from
  `parentDir(publicCliPath)` and degrade to per-project provider compile with
  **no error** if they are not there. The graph helper is resolved the same
  way (`graphHelperImagePath` in `libs/repro_core/src/repro_core/cli_images.nim`),
  but a missing one is an **error naming the expected path**: the engine never
  runs those helpers itself instead.
- Never add `-d:ssl` to the helper image (`apps/entrypoints.txt`, and its
  `nim.c` edge in `repro.nim`), and never route a helper verb that needs TLS
  through it. `tests/integration/t_graph_helper_image_loads_no_openssl.nim`
  fails if either build table gains it or the built image maps OpenSSL.
- The helper image answers only those helper commands and refuses everything
  else with exit 2. Inside it the engine stays the public CLI: anything a
  helper starts or bakes in names `reprobuild`, as it did when the engine ran
  the helper itself.
- The engine still *declares* itself `repro` (`runThinApp("repro")`), so its
  usage text, its diagnostics and its permission to self-spawn internal verbs
  are all independent of the filename. Do not "fix" code that looks for a file
  named `repro` by making the engine's identity depend on its name again — see
  `runningImageIsReproCli`.
- Routing is deliberately narrow: `build` only, progress explicitly quiet,
  stderr not a terminal, no `--daemon`/`REPRO_DAEMON`, none of
  `ClientHandledFlags`. Anything else hands over and pays ~1–3 ms extra. An
  interactive `repro build` always hands over.
- `libs/repro_core/src/repro_core/cli_images.nim` holds the three names and
  the rationale for them.

## Before You Edit a `repro.nim`

Read **[Idiomatic Reprobuild](../user-guide/idiomatic-reprobuild.md)**.
It is the cookbook for using this tool well, and — more to the point —
it enumerates the changes that look like correct use and are not.
Several have been made repeatedly, in good faith, by agents: a
declared-only dependency policy (a soundness hole — four distinct forms
of it have been added and removed, and the enum now carries a comment
saying so); an entropy blessing on the shell (unsound, and the plumbing
looks broken in a way that makes repairing it the route by which the
waiver actually gets made); and "fixes" that improve a monitor evidence
grade without improving the evidence. Each trap is cited to the guard
that stops it.

## When A Commit Or Push Is Refused Over A Pinned Revision

Do not add an exact revision to a recipe (`rev=` or a `/<sha>` URL in
`flake.nix`, an exact `uses:` version in `repro.nim`) to get past a refusal.
A recipe pin is a reviewed statement about which revision is acceptable, not
a way to silence a hook. If the newer revision is the intended upgrade, run
`repro lock update <dependency> [--to <rev>]`: it moves both locks and
rewrites an exact pin wherever one already exists. If the newer revision was
a temporary experiment, drop the develop override with
`repro develop --drop=<dependency>` (or check the sibling out at the pinned
revision). Each refusal prints the exact commands, with the right roots. A
sibling that you develop side by side should be tracked through the lock,
and `repro check` and `repro health` list any exact pin of one, with the
reason written beside it or `no reason stated`.

## Working In A Reprobuild Repo

- **[Idiomatic Reprobuild](../user-guide/idiomatic-reprobuild.md)**: how to use it *well*, and the mistakes that look exactly like correct use. §10 covers the most expensive one — building a prerequisite in a shell script instead of declaring an edge, which costs invalidation and evidence ownership, not just caching.
- **[Test History and Timings](Test-History-And-Timings.md)**: durations, peak RSS, and how a process died live in the host-wide RunQuota observation store — the only durable record. Read this *before* concluding anything from an empty timing query: when the host is unprovisioned, capture is off and queries return empty rather than failing.

## Replaced Systems

- **[Build Systems (Bazel, Buck2, BuildXL, Tup)](Replaces/How-Repro-Replaces-Build-Systems-Like-Bazel-Buck2-BuildXL-and-Tup.md)**: Models the workspace as a type-checked DAG. Enforces hermetic builds using a user-space filesystem monitor shim (`librepro_monitor_shim`) and uses a shared-memory action cache daemon for sub-millisecond cache checks.
- **[Environment & Service Managers (Nix, direnv, devenv, Process Compose, Spack, Conan)](Replaces/How-Repro-Replaces-Environment-and-Service-Managers-Like-Nix-Direnv-Devenv-and-Process-Compose.md)**: Automatically overlays locked environment configurations upon directory entry and uses a `clingo` solver to concretize version constraints. Orchestrates project background services (databases, daemons, queues) natively.
- **[Task Runners (Just, Make)](Replaces/How-Repro-Replaces-Task-Runners-Like-Just-and-Make.md)**: Defines named task scripts within the package DSL that run directly inside the activated dev-env.
- **[Workspace Managers (repo, Git submodules)](Replaces/How-Repro-Replaces-Workspace-Managers-Like-Repo-and-Git-Submodules.md)**: Integrates multi-repository workspace checkout rules (`repos/*.toml`, `repo-sets/*.toml` and the `repro-workspace.toml` settings) with the build graph.
- **[Local Infrastructure Provisioners (Terraform)](Replaces/How-Repro-Replaces-Local-Infrastructure-Provisioners-Like-Terraform.md)**: Declaratively configures local developer machine state (dotfiles, system packages, services) with generation-based rolling updates and rollbacks.
