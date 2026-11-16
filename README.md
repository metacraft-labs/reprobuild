# Reprobuild

[**Documentation**](https://docs.reprobuild.com) · [**Install**](https://docs.reprobuild.com/install) · [**Quickstart**](https://docs.reprobuild.com/tutorials/first-build) · [**CLI Reference**](https://docs.reprobuild.com/reference/commands) · [**llms.txt**](./llms.txt) · [**Agent Guide**](./docs/agents/Repro-Intro-for-Agents.md)

> **Code, machines, and fleets. Defined once, built once.**

Look inside a typical repository and you'll find six descriptions of the same
system: a `Dockerfile`, a Nix flake, a `Makefile` or task runner, a
`docker-compose.yml`, a Terraform module, and a CI pipeline — each with its own
language, its own cache, and its own idea of what your dependencies are.

**Reprobuild** (`repro`) combines core ideas from **BuildXL**, **Nix**, and
**Terraform** to replace them with **one compile-time-verified model** (`repro.nim`,
`home.nim`, `system.nim`): a build graph with automatically tracked dependencies
whose outputs are not just files, but live states — a compiled binary, a
generated config file, a running database, a user account, a system setting, or
a cloud resource. One typed description drives your builds, dependencies, dev
environment, services, and infrastructure across Linux, macOS, and Windows,
catching structural and type errors at compile time before any action runs.

Incremental builds compete with low-level executors such as **Ninja**, user-space
filesystem monitoring (`io-mon`) prevents stale cache hits, and **RunQuota**
coordinates host CPU and memory so concurrent developer and AI-agent sessions do
not thrash the machine. Paired with broad package catalogs, atomic generations,
and in-process **hot code reloading** (`repro watch --hcr`), Reprobuild forms
the foundation of [**ReproOS**](https://github.com/metacraft-labs/reproos) — a
malleable operating system where humans and agents can modify, rebuild, and
reload any layer of a running system on the fly.

---

## 1. Core Philosophy: Modifying any software should be easy!

Imagine you want to fix a bug in Firefox. In a standard setup, this means
spending hours setting up your build tools, matching libraries, and downloading
massive toolchains. Reprobuild is designed so that one command does it all:

```bash
repro develop firefox
```

That is the goal `repro develop` is built toward: clone Firefox and provision
the exact compiler toolchain, libraries, and development tools its build
needs. **This workspace-creating form is planned but not yet implemented**;
see [Getting Started](#2-getting-started) for what the command does today.

What works today is the second half of the story. Say the bug isn't in Firefox
itself, but in Cairo, one of its underlying libraries. Inside a workspace whose
lock set includes Cairo, you type:

```bash
repro develop --only=cairo
```

Reprobuild checks the Cairo repository out side-by-side, plugs it into your
local workspace, and routes the build of the project that depends on it to
compile against your local Cairo copy. When you edit and save a file in Cairo,
the compiler recompiles the change and propagates it up to the dependent
project. Your workspace grows dynamically to match exactly the slice of the
universe you are modifying.

---

## 2. Getting Started

Install `repro` through the official installer for your platform (see the full
[installation guide](https://docs.reprobuild.com/install)):

```sh
# Debian, Ubuntu, Fedora, RHEL — registers the signed apt/dnf repository
curl -fsSL https://get.reprobuild.com/sh | sh

# macOS or Linux with Nix — installs into your Nix profile
curl -fsSL https://get.reprobuild.com/sh | sh -s -- --method nix
```

```powershell
# Windows PowerShell — registers the Metacraft Scoop bucket and installs reprobuild
irm https://get.reprobuild.com/pwsh | iex
```

Inspect the POSIX script first with `curl -fsSL https://get.reprobuild.com/sh | less`
([source](./scripts/install/repro-install.sh); Windows [source](./scripts/install/repro-install.ps1)).
On supported apt/dnf systems it requires root access, checks the downloaded
keyring against a SHA-256 digest pinned in the script, and lets the native
package manager verify repository metadata and handle subsequent upgrades. On
NixOS it prints the declarative configuration change without modifying
`/etc/nixos`.

Or download a prebuilt archive from the
[releases page](https://github.com/metacraft-labs/reprobuild/releases) and put
its `bin/` on your `PATH`:

```bash
# Linux x86_64 — adjust the version and platform to taste
VERSION=0.2.25
PLATFORM=linux-x86_64   # or darwin-aarch64; Windows ships a .zip
curl -fsSLO "https://github.com/metacraft-labs/reprobuild/releases/download/v${VERSION}/reprobuild-${VERSION}-${PLATFORM}.tar.gz"
tar -xzf "reprobuild-${VERSION}-${PLATFORM}.tar.gz"
export PATH="${PWD}/reprobuild-${VERSION}-${PLATFORM}/bin:${PATH}"

repro version
```

Keep `bin/` and `lib/` together — `repro` loads its runtime libraries relative
to its own location, so moving the executable out of the unpacked tree on its
own prevents startup.

> **Archive verification:** releases from `v0.1.4` onward publish
> `SHA256SUMS` next to the archives. After downloading both, use
> `sha256sum -c SHA256SUMS`. This detects corruption, but the manifest shares
> the archive's origin and does not authenticate a compromised release.
> The installer's tarball fallback (including on macOS) requires a separate
> release verifier, which `/sh` does not bundle, and fails closed without it.
> The [release-signing allowlist](./scripts/release-signing/trusted-release-keys.txt)
> currently contains no release-key fingerprints. Do not assume archives are
> authenticated by signatures; see [release signing](./docs/release-signing.md).

Prefer to build from source, or on a platform with no published archive? See
[CONTRIBUTING.md](./CONTRIBUTING.md).

There is nothing else to install — no Docker, no language-specific version
managers, no global toolchains.

`repro develop` works inside a workspace or a project that already exists. It
does not yet create a workspace from a bare package name, so `repro develop
firefox` run from an arbitrary directory fails with `develop target module not
found`. The forms that work today:

```bash
repro develop --only=<dependency>        # check one dependency of the lock set out and build against it
repro develop --all                      # the same for every dependency of the lock set
repro develop <name> --source=<path>     # register a checkout you already have
repro develop <target> -- <command>      # run a command in a local project's environment
```

The workspace-creating form, which clones the necessary repositories for any
package in the catalog from an empty directory, is planned and not yet
available.

---

## 3. Starting a New Project

For your own software, create a directory containing a `repro.nim` (described
below) and step into its environment:

```bash
mkdir my-app && cd my-app   # then write repro.nim

# Enter the project environment — every tool pinned by repro.nim
repro shell

# Build, test, and start the declared services
repro build
repro test
repro up
```

Instead of maintaining separate package specifications, Dockerfiles, task
runners, and Nix expressions, the project's configuration is defined in a
standard, compile-time verified `repro.nim` file:

```nim
import repro_dsl_stdlib

package app:
  # BUILD-platform tools that drive the build (compilers, generators)
  nativeBuildDeps:
    "nim >=2.2 <3.0"
    "cargo >=1.75 <2.0"
    "pnpm >=9 <10"
    "protoc >=25 <26"

  # HOST-platform libraries the produced binaries link against
  buildDeps:
    "openssl >=3.3 <4.0"

  # Tools and libraries needed at runtime; propagated to consumers
  runtimeDeps:
    "postgres >=16 <17"

  config:
    ## Port the API listens on during development.
    port: int = 8080

  ## Development database — provisioned from the catalog like any
  ## other dependency and supervised by `repro up`.
  service db:
    executable postgres.executable("postgres")
    args "-D", "data/db"

  # Rust library compiled from source
  library "rust_lib":
    build:
      cargo.build(workDir = "rust_lib", output = "rust_lib/lib/libcore.a")

  # Hermetic, sandbox-monitored build recipes
  executable "backend":
    build:
      # Generate source files from protobuf definitions
      let genSources = protoc(glob("proto/*.proto"), lang = "nim",
                              outputDir = "src/proto")

      # Compile and link the Nim binary against the Rust library
      nim.c(source = "src/main.nim", extraInputs = genSources,
            libraries = [rust_lib], output = "out/backend")

  tasks:
    ## Builds release binaries and publishes the workspace bundle.
    task "publish":
      pnpm.run("publish")
```

The typed tools mirror the commands you already know — `cargo.build(...)` is
`cargo build`, `nim.c(...)` is `nim c`, and tools without subcommands, like
`protoc` and `postgres`, are plain functions named after their binary.

Because `repro.nim` is ordinary Nim, your editor gives you go-to-definition,
autocomplete, and type errors at authoring time — a misspelled option or a
type mismatch fails compilation, not your 3 a.m. deploy.

> **DSL imports & dependency blocks:** Existing recipes import
> `repro_project_dsl` and `repro_dsl_stdlib/*` (consolidating onto
> `import reprobuild` and targeted `import reprobuild/dsl[/<module>]` modules).
> `uses:` is shorthand when build and host platforms match, whereas
> `nativeBuildDeps` / `buildDeps` / `runtimeDeps` separate cross-compilation
> toolchains from target-linked libraries and runtime services.

---

## 4. Measured Performance

Reprobuild pairs a 520 KB native daemon client and a shared-memory grow-only
action index with user-space `io-mon` filesystem monitoring — matching
unmonitored low-level executors while guaranteeing sound input tracking:

| Benchmark | Reprobuild | Baseline / Reference | Notes |
| --- | --- | --- | --- |
| **Warm incremental rebuild** *(single-header edit, 2,400-action C++/Rust/Nim graph)* | **`3.8 s`** | `3.9 s` Ninja · `6.4 s` `ccache` + Make · `14.1 s` GNU Make | Full `io-mon` read verification active (`1.04×` Ninja throughput; `< 2 ms` shared-memory no-op check) |
| **Distributed build & test sharding** *(64 workers, `repro test --shard K/N`)* | **`62.1×` speedup** | `64.0×` ideal linear scaling | Content-addressed action cache + historical duration-balanced test partitioning |
| **Multi-session host concurrency** | **Bounded RSS & CPU** | Uncoordinated parallel `cargo`/`ninja` OOMs | **RunQuota** leases CPU cores and peak-RSS memory budgets across concurrent humans and AI agents |

---

## 5. Reprobuild vs Your Favorite Tools

If you are already familiar with the modern DevOps and build toolchain,
Reprobuild maps directly onto concepts you know:

- **Reprobuild is like Nix & Spack** in the sense that it pins every build
  tool and library dependency to a precise version. It differs by supporting
  **Windows as a first-class platform**, by using a **compile-time-checked
  DSL** instead of an untyped lazy language, and by keeping store artifacts
  **path-independent**, so caches relocate cleanly across machines.
- **Reprobuild is like Terraform** in the sense that it handles declarative
  desired-state reconciliation for local machine state and cloud resources,
  but differs by integrating directly with your build system and host
  configuration management — any repository can define typed `resourceType`
  providers, and **it can reuse existing Terraform providers**.
- **Reprobuild is like Bazel & Buck2** in the sense that it models the
  workspace as a build graph of targets with remote caching. It differs by
  describing builds in standard Nim rather than Starlark, by shipping as a
  single fast native binary with no JVM daemon (Bazel) and no separately
  deployed remote-execution service, and by supporting native **distributed
  builds** and **test suite sharding** out of the box.
- **Reprobuild is like BuildXL & Tup** by enforcing hermeticity through
  filesystem monitoring. It differs by using the
  [io-mon](https://github.com/metacraft-labs/io-mon) user-space filesystem
  interceptor to **automatically discover all build dependencies** rather
  than requiring kernel-level drivers or FUSE filters.
- **Reprobuild is like Ninja** in the sense that it is optimized to
  **execute incremental builds at maximum speed**. It differs by adding
  features such as **OOM protection** that enable agents to execute
  concurrent builds without thrashing.
- **Reprobuild is like mise & devbox** for activating per-project tool
  versions, but the versions come from the **same lock file that drives the
  build graph**, so your shell, your CI, and your build can never disagree.
- **Reprobuild is like Live++** by supporting hot code reloading, but does
  it on all operating systems.
- **Reprobuild is like direnv**, but is completely zero-bypass — since
  compiler tools are scoped to the project environment, **agents can't
  forget to run it**.
- **Reprobuild is like Docker Compose & Process Compose**, but it
  **type-checks** your service configuration — and services are provisioned
  from source-built packages, not opaque images.

Reprobuild unifies all of these tools behind one concept: a build graph of
tracked inputs and outputs where the outputs are not restricted to files, and
can also represent live states (the activation of a system setting, the launch
of a service, or the creation of a user or database).
Reprobuild can build files, system configurations, and entire cloud fleets on
the basis of the same abstraction. The outputs or side-effects from executing
the edges are automatically cleaned up when they are no longer relevant.

---

## 6. Reproducible by Construction

The name is a promise. Every action in the graph runs hermetically, with its
inputs content-addressed and its filesystem behavior monitored, so:

- **Identical inputs produce identical outputs — bit for bit.** Builds are
  verified by building twice under deliberately varied conditions and
  asserting byte-equality.
- **Caching is correct, not heuristic.** An artifact is reused only when the
  complete input fingerprint matches — across branches, worktrees, machines,
  and teammates. No more `make clean` superstition.
- **Provenance is a build output.** Because the graph records every input of
  every artifact, dependency inventories (SBOMs) and verifiable build
  attestations fall out of ordinary builds instead of requiring a separate
  scanning pipeline.
- **Environments never drift.** The same guarantees extend to dev
  environments, services, and machine configuration — with atomic,
  generation-based rollback when you change your mind.

---

## 7. The Same Graph, at Distro Scale: ReproOS

Reprobuild is the foundation of
[ReproOS](https://github.com/metacraft-labs/reproos) — a malleable Linux
distribution where the entire system is one Reprobuild graph: every package is
built from source through a full-source bootstrap rooted in a hand-auditable
seed of a few hundred bytes, system and home profiles compile into atomic,
rollback-friendly generations, whole-system images are byte-reproducible so a
running machine can prove via hardware remote attestation which configuration it
executes, and in-process hot code reloading (`repro watch --hcr`) lets humans
and AI agents modify running software on the fly. If Reprobuild makes any
_project_ reproducible and modifiable, ReproOS applies the same model to the
operating system underneath it.

---

## 8. Key CLI Commands

Reprobuild wraps all development workflows under one CLI.

### Build & Test

- `repro build [target]` — compile and materialize targets.
- `repro test` — run the workspace test suite.
- `repro watch` — start a continuous watch-style build loop.

### Environment & Services

- `repro shell` — enter an interactive, activated dev-env subshell.
- `repro exec -- [cmd]` — run a single command within the dev-env context.
- `repro up` / `repro down` — start or stop the project's declared services.

### Package Management

- `repro add <repo> --remote=URL` / `repro remove <repo>` — add a repository
  to, or remove it from, the workspace (develop-mode policy and workspace
  membership; these do not manage package dependencies).
- `repro why [package]` — explain why a dependency is present.

### Task Running

- `repro tasks` — list all named automation tasks registered in `repro.nim`.
- `repro run [task] -- [args]` — run an environment task, forwarding
  positional arguments.

### Workspace & Develop Mode

- `repro develop --only=<dependency>` / `--all` — check dependencies of the
  workspace's lock set out locally and link them in-process;
  `repro develop <name> --source=<path>` registers an existing checkout.
- `repro workspace sync` — clone and update all repositories declared in
  `repro-workspace.toml`.
- `repro workspace status` — audit git status and alignment across all
  workspace repos.
- `repro workspace branch-roles` — show which branch each branch role
  (`mainline`, `unstable`, `staging`, `stable`, `production`, `lts`, and any
  custom role) resolves to in every repo, and the fallback chain behind it.
  `--to=<role>` or a shorthand such as `--unstable` prints one role. Reads the
  manifests only; nothing is fetched.
- `repro sync --to=<role>` — reconcile each repo's current branch with the
  branch that role resolves to there (fast-forward, or report what diverged;
  `--rebase` / `--merge` integrate the rest). `repro switch --to=<role>` moves
  every repo onto that branch instead, and `repro branch <path> --from=<role>`
  forks a new workspace cut from it. Each built-in role has a shorthand
  (`--mainline`, `--unstable`, `--staging`, `--stable`, `--production`,
  `--lts`) that means exactly the `--to=` / `--from=` spelling; custom roles
  are named with `--to=` / `--from=` only. A role a repo does not declare falls
  back toward its mainline, and every report names the chain
  (`latest (unstable → mainline)`); a role that IS declared but whose branch
  the remote lacks is refused as `no_role_ref`, never redirected to another
  branch.

Workspace cloning shares a local Git object pool by default; pass
`--clone-objects=none` for standalone checkouts or
`--clone-objects=private=<dir>` for an isolated pool (see
[Join a Workspace](https://docs.reprobuild.com/guides/workspaces/join-a-workspace)).

### Local Infrastructure

- `repro infra plan` / `repro infra apply` — plan or apply declarative local
  machine profiles.
- `repro home plan` / `repro home apply` / `repro home rollback` — preview,
  apply, or roll back user-level `home.nim` generations.
- `repro system rollback` — roll back the operating system to a previous
  generation.

---

## 9. Learn More

- **User Documentation:** [docs.reprobuild.com](https://docs.reprobuild.com)
  (built from [`docs/users/`](./docs/users/content/index.md)) covers
  installation, tutorials, how-to guides, architecture concepts, `Coming from…`
  migration guides, and the CLI reference.
- **For AI Agents:** read [`llms.txt`](./llms.txt) for the topic-based discovery
  index and [`docs/agents/Repro-Intro-for-Agents.md`](./docs/agents/Repro-Intro-for-Agents.md)
  (plus its linked per-topic replacement and idiomatic guides) when working
  inside a checkout; [`docs.reprobuild.com/llms-full.txt`](https://docs.reprobuild.com/llms-full.txt)
  serves the single-file assembled reference for external RAG indexers.
- **Subsystem Deep Dives:** see [`docs/capabilities.md`](./docs/capabilities.md),
  [`docs/dependency-collection.md`](./docs/dependency-collection.md), and
  [`docs/bootstrap-build-graph.md`](./docs/bootstrap-build-graph.md). The
  internal design specifications live in a separate project-management
  repository.
- **ReproOS:** the Reprobuild-based Linux distribution lives at
  [metacraft-labs/reproos](https://github.com/metacraft-labs/reproos).
- **Contributing:** see [CONTRIBUTING.md](./CONTRIBUTING.md) for building
  Reprobuild itself and the development workflow.
- **Commercial offerings** (hosted caches, distributed execution, and
  enterprise services) live at [reprobuild.com](https://reprobuild.com).

## 10. License

Apache License 2.0 (`Apache-2.0`) — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
Copyright 2026 Metacraft Labs. The `repro` CLI and engine in this repository
are free software; commercial services are optional and never required to use
them.
