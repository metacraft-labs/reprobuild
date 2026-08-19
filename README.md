# Reprobuild

> **All the world's software, as reproducible development environments.**

Look inside a typical repository and you'll find six descriptions of the same
system: a `Dockerfile`, a Nix flake, a `Makefile` or task runner, a
`docker-compose.yml`, a Terraform module, and a CI pipeline — each with its own
language, its own cache, and its own idea of what your dependencies are.

Reprobuild (`repro`) replaces them with **one compile-time-verified model**: a
build graph whose nodes are not just files but states — a compiled binary, a
generated config file, a running database, a system setting, a cloud resource.
One description drives your builds, your dependencies, your dev environment,
your services, and your infrastructure, with the same caching, the same
hermeticity guarantees, and the same rollback story everywhere.

---

## 1. Core Philosophy: Modifying any software should be easy!

Imagine you want to fix a bug in Firefox. In a standard setup, this means
spending hours setting up your build tools, matching libraries, and downloading
massive toolchains. With Reprobuild, you simply run:

```bash
repro develop firefox
```

This instantly clones Firefox and provisions the exact compiler toolchain,
libraries, and development tools its build needs.

But what if the bug isn't in Firefox itself, but in Cairo, one of its
underlying libraries? Instead of fork-and-link hell, you just type:

```bash
repro develop cairo
```

Reprobuild pulls down the Cairo repository side-by-side, plugs it into your
local workspace, and automatically routes Firefox's build system to compile
against your local Cairo copy. When you edit and save a file in Cairo, the
compiler recompiles the change and propagates it instantly up to Firefox. Your
workspace grows dynamically to match exactly the slice of the universe you are
modifying.

---

## 2. Getting Started

Install `repro` by downloading the prebuilt archive for your platform from the
[releases page](https://github.com/metacraft-labs/reprobuild/releases) and
putting its `bin/` on your `PATH`:

```bash
# Linux x86_64 — adjust the version and platform to taste
VERSION=0.1.3
PLATFORM=linux-x86_64   # or darwin-aarch64; Windows ships a .zip
curl -fsSLO "https://github.com/metacraft-labs/reprobuild/releases/download/v${VERSION}/reprobuild-${VERSION}-${PLATFORM}.tar.gz"
tar -xzf "reprobuild-${VERSION}-${PLATFORM}.tar.gz"
export PATH="${PWD}/reprobuild-${VERSION}-${PLATFORM}/bin:${PATH}"

repro --version
```

Keep `bin/` and `lib/` together — `repro` loads its runtime libraries relative
to its own location, so moving the executable out of the unpacked tree on its
own will break it.

> **Not yet available:** a `curl … | sh` installer at `get.reprobuild.com`.
> That host does not exist yet; do not expect the one-liner you may have seen
> elsewhere to work. Releases from `v0.1.4` onward also publish a `SHA256SUMS`
> file next to the archives — verify against it with
> `sha256sum -c SHA256SUMS` once you have downloaded both. Note that
> `SHA256SUMS` is served from the same origin as the archive, so it protects
> against a truncated or corrupted download, not against a compromised
> release; signed releases are still to come.

Prefer to build from source, or on a platform with no published archive? See
[CONTRIBUTING.md](./CONTRIBUTING.md).

There is nothing else to install — no Docker, no language-specific version
managers, no global toolchains. And there is nothing to set up before the
command from the story above works, from any directory on your machine:

```bash
repro develop firefox
```

`repro develop` is workspace-creating: it clones the necessary repositories,
provisions the pinned toolchains and libraries, wires up the build graph, and
drops you into a ready development environment for any package in the catalog
— whether or not you have ever checked anything out before.

---

## 3. Starting a New Project

For your own software, initialize a project from a template and step into its
environment:

```bash
repro init app my-app && cd my-app

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
    postgres(dataDir = "data/db", port = port)

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

---

## 4. Reprobuild vs Your Favorite Tools

If you are already familiar with the modern DevOps and build toolchain,
Reprobuild maps directly onto concepts you know:

- **Reprobuild is like Nix & Spack** in the sense that it pins every build
  tool and library dependency to a precise version. It differs by supporting
  **Windows as a first-class platform**, by using a **compile-time-checked
  DSL** instead of an untyped lazy language, and by keeping store artifacts
  **path-independent**, so caches relocate cleanly across machines.
- **Reprobuild is like Terraform** in the sense that it handles declarative
  desired-state reconciliation for local machine state and cloud resources,
  but differs by being seamlessly integrated with your build system and host
  configuration management — and **it can reuse existing Terraform
  providers**.
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

Reprobuild unifies all of these tools behind one simple concept: a build graph
of arbitrary inputs and outputs where the nodes are not necessarily files, but
a more abstract notion of states (the activation of a particular system
setting, the launch of a daemon, the creation of a user or a database, etc.).
Reprobuild can build files, system configurations, and entire cloud fleets on
the basis of the same abstraction. The outputs or side-effects from executing
the edges are automatically cleaned up when they are no longer relevant.

---

## 5. Reproducible by Construction

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

## 6. The Same Graph, at Distro Scale: ReproOS

Reprobuild is the foundation of
[ReproOS](https://github.com/metacraft-labs/reproos) — a Linux distribution
where the entire system is one Reprobuild graph: every package is built from
source through a full-source bootstrap rooted in a hand-auditable seed of a
few hundred bytes, system configuration compiles into atomic,
rollback-friendly generations, and whole-system images are byte-reproducible
— which is what lets a running ReproOS machine prove, via hardware remote
attestation, exactly which configuration it is executing. If Reprobuild makes
any _project_ reproducible and modifiable, ReproOS applies the same model to
the operating system underneath it.

---

## 7. Key CLI Commands

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

- `repro add [package]` / `repro remove [package]` — manage dependencies.
- `repro search [query]` / `repro why [package]` — explore the catalog and
  explain why a dependency is present.
- `repro upgrade` — update dependencies within their declared constraints.

### Task Running

- `repro tasks` — list all named automation tasks registered in `repro.nim`.
- `repro run [task] -- [args]` — run an environment task, forwarding
  positional arguments.

### Workspace & Develop Mode

- `repro develop [package]` — clone a dependency locally and link it
  in-process.
- `repro workspace sync` — clone and update all repositories declared in
  `repro-workspace.toml`.
- `repro workspace status` — audit git status and alignment across all
  workspace repos.

### Local Infrastructure

- `repro infra plan` / `repro infra apply` — plan or apply declarative local
  machine profiles.
- `repro infra rollback` — roll back the local system to a previous
  generation.

---

## 8. Learn More

- **Design specifications:** the complete architecture is specified in
  [metacraft-labs/reprobuild-specs](https://github.com/metacraft-labs/reprobuild-specs)
  — one document per subsystem, from the package model to hermetic
  execution and the CLI surface.
- **ReproOS:** the Reprobuild-based Linux distribution lives at
  [metacraft-labs/reproos](https://github.com/metacraft-labs/reproos).
- **Contributing:** see [CONTRIBUTING.md](./CONTRIBUTING.md) for building
  Reprobuild itself and the development workflow.
- **Commercial offerings** (hosted caches, distributed execution, and
  enterprise services) live at [reprobuild.com](https://reprobuild.com).

## 9. License

MIT. The `repro` CLI and engine in this repository are free software;
commercial services are optional and never required to use them.
