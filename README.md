# Reprobuild

> **All the world's software, as reproducible development environments.**

Reprobuild (`repro`) is a unified build system, package and configuration manager, development environment coordinator, and infrastructure provisioner (covering both local systems and cloud resources). By folding these layers into a single cohesive description, Reprobuild eliminates the fragmented boundary between "how code is compiled," "how dependencies are resolved," and "how environments are configured."

---

## 1. Core Philosophy: Modifying any software should be easy!

Imagine you want to fix a bug in Firefox. In a standard setup, this means spending hours setting up your build tools, matching libraries, and downloading massive toolchains. With Reprobuild, you simply run:

```bash
repro develop firefox
```

This instantly clones Firefox and provisions the exact compiler toolchain, development packages, databases, and any required cloud resources.

But what if the bug isn't in Firefox itself, but in Cairo, one of its underlying libraries? Instead of fork-and-link hell, you just type:

```bash
repro develop cairo
```

Reprobuild pulls down the Cairo repository side-by-side, plugs it into your local workspace, and automatically routes Firefox's build system to compile against your local Cairo copy. When you edit and save a file in Cairo, the compiler recompiles the change and propagates it instantly up to Firefox. Your workspace grows dynamically to match exactly the slice of the universe you are modifying.

---

## 2. Declarative, Strongly-Typed DSL

Instead of maintaining separate package specifications, Dockerfiles, task runners, and Nix expressions, a project's configuration is defined in a standard, compile-time verified `repro.nim` file:

```nim
import repro_dsl_stdlib

package app:
  buildDeps:
    "cargo >=1.75 <2.0"
    "pnpm >=8 <9"
    "nim >=2.0 <3.0"
    "protoc >=25 <26"

  # Background services (databases, queues, daemons) needed in dev and prod
  serviceDeps:
    postgres:
      image = "postgres:16-alpine"
      ports = ["5432:5432"]

  devEnv:
    ## Builds release binaries and publishes the workspace bundle
    task "publish":
      pnpm.run("publish")

  # Rust library compiled from source
  library "rust_lib":
    build:
      cargo.build(workDir = "rust_lib", output = "rust_lib/lib/libcore.a")

  # Hermetic, sandbox-monitored build recipes
  executable "backend":
    build:
      # Generate source files from protobuf definitions
      let genSources = protoc.compile(glob("proto/*.proto"), lang = "nim", outputDir = "src/proto")

      # Compile and link Nim binary with the Rust library dependency
      nim.c(source = "src/main.nim", extraInputs = genSources, libraries = [rust_lib], output = "out/backend")

  executable "frontend":
    build:
      pnpm.build(workDir = "frontend", output = "out/frontend")
```

---

## 3. Reprobuild vs Your Favourite Tools

If you are already familiar with the modern DevOps and build toolchain, Reprobuild maps directly onto concepts you know:

*   **Reprobuild is like Nix & Spack** in the sense that it pins every build tool and library dependency to a precise version. It differs from them by supporting **Windows and macOS** natively.
*   **Reprobuild is like Terraform** in the sense that it handles declarative desired-state reconciliation for local machine state and cloud resources, but differs by being seamlessly integrated with your build system and host configuration management—and **it can reuse all existing Terraform providers**.
*   **Reprobuild is like Bazel & Buck2** in the sense that it models the workspace as a build graph of targets with remote caching. It differs from them by using standard Nim code and compiling into a fast, native binary rather than requiring a JVM daemon or Starlark, while supporting native **distributed builds** and **test suite sharding**.
*   **Reprobuild is like BuildXL & Tup** by enforcing hermeticity through filesystem monitoring. It differs from them by using the [io-mon](file:///Users/zahary/m/io-mon-fixes/io-mon) user-space filesystem interceptor to **automatically discover all build dependencies** rather than requiring kernel-level drivers or FUSE filters.
*   **Reprobuild is like Ninja** in the sense that it is optimized to **execute incremental builds at maximum speed**. It differs from it by adding features such as **OOM protection** that enable agents to execute concurrent builds without thrashing.
*   **Reprobuild is like Live++** by supporting hot code reloading, but does it on all operating systems.
*   **Reprobuild is like direnv**, but is completely zero-bypass—since compiler tools are scoped to the project environment, **agents can't forget to run it**.
*   **Reprobuild is like Docker Compose & Process Compose**, but it **type-checks** your service configuration.

---

## 4. Key CLI Commands

Reprobuild wraps all development workflows under one CLI.

### Build & Test
*   `repro build [target]` — compile and materialize targets.
*   `repro test` — run the workspace test suite.
*   `repro watch` — start a continuous watch-style build loop.

### Environment & Services
*   `repro shell` — enter an interactive, activated dev-env subshell.
*   `repro exec -- [cmd]` — run a single command within the dev-env context.
*   `repro service start [service]` — spin up background services (e.g. database).
*   `repro service status` — check the state of running services.

### Task Running
*   `repro tasks` — list all named automation tasks registered in `repro.nim`.
*   `repro run [task] -- [args]` — run an environment task, forwarding positional arguments.

### Workspace & Develop Mode
*   `repro develop [package]` — clone a dependency locally and link it in-process.
*   `repro workspace sync` — clone and update all repositories declared in `repro-workspace.toml`.
*   `repro workspace status` — audit git status and alignment across all workspace repos.

### Local Infrastructure
*   `repro infra plan` / `repro infra apply` — plan or apply declarative local machine profiles.
*   `repro infra rollback` — roll back the local system to a previous generation.

---

## 5. Developing Reprobuild

This repository is the public `metacraft-labs/reprobuild` product repository.

### Local Tooling
- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.

### Nix Dev Shell
`nix develop` activates the compiler and library toolchain. To handle private dependency overrides on development hosts, `scripts/dev-shell.sh` auto-detects sibling checkouts:
```bash
# Clone the sibling native recorder (if developer credentials are configured):
gh repo clone metacraft-labs/codetracer-native-recorder ../codetracer-native-recorder

# Enter the dev shell:
bash scripts/dev-shell.sh
```

## 6. License

MIT
