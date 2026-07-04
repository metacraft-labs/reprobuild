# Reprobuild User Manual

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

## 2. The Three Modes of Reprobuild

Reprobuild workspace configuration coexists in three different modes depending on the level of declarative ceremony you need:

| Mode | Name | Description | Recommended For |
|---|---|---|---|
| **Mode 1** | Layout-as-Manifest | Zero configuration file. Reprobuild walks `apps/` and `libs/`, infers targets, scans source imports, and compiles dynamically. | Rapid prototyping, clean monorepos. |
| **Mode 2** | Ecosystem Delegation | Leverages existing package manager manifests (`Cargo.toml`, `package.json`, `CMakeLists.txt`) and sequences native tools. | Brownfield migration of existing codebases. |
| **Mode 3** | Curated `repro.nim` | A minimal, compile-time verified Nim DSL that explicitly declares package dependencies, services, tasks, and build rules. | New projects and complex multi-language workspaces. |

---

## 3. The `repro.nim` DSL Grammar

In a Mode 3 project, the configuration is defined in a standard, type-safe `repro.nim` file. Below is a comprehensive reference example illustrating all major DSL features:

```nim
import repro_dsl_stdlib

package app:
  # 1. Build Dependencies (compiler tools, code generators, build platform tools)
  buildDeps:
    "cargo >=1.75 <2.0"
    "pnpm >=8 <9"
    "nim >=2.0 <3.0"
    "protoc >=25 <26"

  # 2. Service Dependencies (databases, queues, daemons needed in dev and prod)
  serviceDeps:
    postgres:
      image = "postgres:16-alpine"
      ports = ["5432:5432"]

  # 3. Developer Shell Environment & Task Automation
  devEnv:
    ## Builds release binaries and publishes the workspace bundle
    task "publish":
      pnpm.run("publish")

  # 4. Libraries compiled from source
  library "rust_lib":
    build:
      cargo.build(workDir = "rust_lib", output = "rust_lib/lib/libcore.a")

  # 5. Executables linking cross-language outputs
  executable "backend":
    build:
      # Generate source files from protobuf definitions
      let genSources = protoc.compile(glob("proto/*.proto"), lang = "nim", outputDir = "src/proto")

      # Compile and link Nim binary with the Rust static library dependency
      nim.c(source = "src/main.nim", extraInputs = genSources, libraries = [rust_lib], output = "out/backend")

  # 6. Web applications
  executable "frontend":
    build:
      pnpm.build(workDir = "frontend", output = "out/frontend")
```

### DSL Key Elements:
*   **`buildDeps`**: Declares host-platform build toolchains and generators.
*   **`serviceDeps`**: Configures runtime service dependencies (like databases). They live outside the `devEnv` block because they are production dependencies too.
*   **`devEnv`**: Declares developer-only configurations (like subshell environments and named CLI tasks).
*   **`task`**: Declares automated workflows.
    *   **Doc-Comments (`##`)**: Used directly inside the block to document the task.
    *   **Direct Statements**: Task actions are written directly inside the block body.
*   **`library` / `executable`**: Enclose the hermetic `build:` block recipes.
*   **Cross-Language Linking**: Libraries produced by one language toolchain (e.g. `rust_lib` built by `cargo.build`) can be directly linked as static archives (via the `libraries = [...]` argument) inside compiling rules of another toolchain (e.g. `nim.c`).

---

## 4. Key CLI Commands Reference

Reprobuild integrates all build, runtime, task, and workspace workflows into a single CLI:

### Build, Testing & Graph
*   `repro build [target]` — compile and materialize targets.
*   `repro test` — run the workspace test suite.
*   `repro watch` — start a continuous watch-style build loop.
*   `repro graph` — output the build target graph (JSON format via `--json`).
*   `repro capabilities` — query installed build-system-neutral capability configuration (JSON by default, text via `--format=text`).
*   `repro --version` — print version and self-identification info of the `repro` binary.

### Shell Environment & Services
*   `repro shell` — enter an interactive, activated dev-env subshell.
*   `repro exec -- [cmd]` — run a single command within the dev-env context.
*   `repro service start [service]` — spin up background services (e.g. database).
*   `repro service stop [service]` — stop background services.
*   `repro service restart [service]` — restart background services.
*   `repro service status` — check the state of running services.

### Task Running & Local State
*   `repro tasks` — list all named automation tasks registered in `repro.nim`.
*   `repro run [task] -- [args]` — run an environment task, forwarding positional arguments.
*   `repro home apply` — declaratively reconcile and apply local home profile configurations (dotfiles, settings, local shell integration).

### Workspace & Develop Mode
*   `repro develop [package]` — clone a package and auto-provision its development resources.
*   `repro deps refresh` — update inferred inter-package dependency edges.

### Store & Cache Management
*   `repro store serve` — serve the local/remote build-artifact store cache endpoint.
*   `repro store daemon install` — install the store cache daemon as a system service (systemd/launchd/Windows Service).

---

## 5. Technical Highlights: Reprobuild vs Other Tools

If you are already familiar with the modern DevOps and build toolchain, Reprobuild maps directly onto concepts you know:

*   **Nix & Spack**: Pins every build tool and library dependency to a precise version. It differs from them by supporting **Windows and macOS** natively.
*   **Terraform**: Handles declarative desired-state reconciliation for local machine state and cloud resources, but differs by being seamlessly integrated with your build system and host configuration management—and **it can reuse all existing Terraform providers**.
*   **Bazel & Buck2**: Models the workspace as a build graph of targets with remote caching. It differs by using standard Nim code and compiling into a fast, native binary rather than requiring a JVM daemon or Starlark, while supporting native **distributed builds** and **test suite sharding**.
*   **BuildXL & Tup**: Enforces hermeticity through filesystem monitoring. It differs from them by using the [io-mon](file:///Users/zahary/m/io-mon-fixes/io-mon) user-space filesystem interceptor to **automatically discover all build dependencies** rather than requiring kernel-level drivers or FUSE filters.
*   **Ninja**: Optimized to **execute incremental builds at maximum speed**. It differs from it by adding features such as **OOM protection** that enable agents to execute concurrent builds without thrashing.
*   **Live++**: Supports hot code reloading, but does it on all operating systems.
*   **direnv**: Completely zero-bypass—since compiler tools are scoped to the project environment, **agents can't forget to run it**.
*   **Docker Compose & Process Compose**: Orchestrates development services, but **type-checks** your service configuration.
