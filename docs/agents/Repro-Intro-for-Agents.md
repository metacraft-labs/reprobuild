# Reprobuild for Experienced Developers & AI Agents

Reprobuild is a unified build, dependency, environment, and workspace tool.

## Architecture & Grepable Keywords

Reprobuild models the workspace as a directed acyclic graph (DAG) of type-checked actions defined in the **`repro.nim`** DSL. Sibling repositories declared in **`repro-workspace.toml`** are routed dynamically using **`repro develop`** (develop-mode). Build hermeticity is enforced using the **`librepro_monitor_shim`** user-space filesystem interceptor, and execution is cached locally through a per-edge disk store fronted by a host-wide **shared-memory grow-only index** that every engine inserts into directly. Package toolchains are concretized using a **`clingo`** solver, and background services are orchestrated using **`servicePlaceholder`** declarations.

## `repro` Is Two Binaries

`repro` on `PATH` is a ~520 KB **thin daemon client**
(`apps/repro-client/repro_client.nim`). It hands a routable `repro build` to
the already-running per-user daemon and `execv`s the ~17 MB **engine**,
installed beside it as **`reprobuild`** (`apps/repro/repro.nim`), for
everything else — every other verb, and every build it cannot route.

Practical consequences when you are working in this repo:

- `just build` / `scripts/build_apps.sh` produce **both** `build/bin/repro`
  and `build/bin/reprobuild`. A tree with only one of them is not a working
  tree; `scripts/bootstrap_guard.sh` checks for both.
- Keep them **siblings**. `siblingTryCompileProviderPath` /
  `siblingStandardProviderPath` resolve the Tier-2a/2b provider binaries from
  `parentDir(publicCliPath)` and degrade to per-project provider compile with
  **no error** if they are not there.
- The engine still *declares* itself `repro` (`runThinApp("repro")`), so its
  usage text, its diagnostics and its permission to self-spawn internal verbs
  are all independent of the filename. Do not "fix" code that looks for a file
  named `repro` by making the engine's identity depend on its name again — see
  `runningImageIsReproCli`.
- Routing is deliberately narrow: `build` only, progress explicitly quiet,
  stderr not a terminal, no `--daemon`/`REPRO_DAEMON`, none of
  `ClientHandledFlags`. Anything else hands over and pays ~1–3 ms extra. An
  interactive `repro build` always hands over.
- `libs/repro_core/src/repro_core/cli_images.nim` holds the two names and the
  rationale for them.

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

## Working In A Reprobuild Repo

- **[Idiomatic Reprobuild](../user-guide/idiomatic-reprobuild.md)**: how to use it *well*, and the mistakes that look exactly like correct use. §10 covers the most expensive one — building a prerequisite in a shell script instead of declaring an edge, which costs invalidation and evidence ownership, not just caching.
- **[Test History and Timings](Test-History-And-Timings.md)**: durations, peak RSS, and how a process died live in the host-wide RunQuota observation store — the only durable record. Read this *before* concluding anything from an empty timing query: when the host is unprovisioned, capture is off and queries return empty rather than failing.

## Replaced Systems

- **[Build Systems (Bazel, Buck2, BuildXL, Tup)](Replaces/How-Repro-Replaces-Build-Systems-Like-Bazel-Buck2-BuildXL-and-Tup.md)**: Models the workspace as a type-checked DAG. Enforces hermetic builds using a user-space filesystem monitor shim (`librepro_monitor_shim`) and uses a shared-memory action cache daemon for sub-millisecond cache checks.
- **[Environment & Service Managers (Nix, direnv, devenv, Process Compose, Spack, Conan)](Replaces/How-Repro-Replaces-Environment-and-Service-Managers-Like-Nix-Direnv-Devenv-and-Process-Compose.md)**: Automatically overlays locked environment configurations upon directory entry and uses a `clingo` solver to concretize version constraints. Orchestrates project background services (databases, daemons, queues) natively.
- **[Task Runners (Just, Make)](Replaces/How-Repro-Replaces-Task-Runners-Like-Just-and-Make.md)**: Defines named task scripts within the package DSL that run directly inside the activated dev-env.
- **[Workspace Managers (repo, Git submodules)](Replaces/How-Repro-Replaces-Workspace-Managers-Like-Repo-and-Git-Submodules.md)**: Integrates multi-repository workspace checkout rules (`repro-workspace.toml`) with the build graph.
- **[Local Infrastructure Provisioners (Terraform)](Replaces/How-Repro-Replaces-Local-Infrastructure-Provisioners-Like-Terraform.md)**: Declaratively configures local developer machine state (dotfiles, system packages, services) with generation-based rolling updates and rollbacks.
