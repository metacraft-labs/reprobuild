---
title: Command equivalents
description: The reprobuild command closest to each command of Nix, Home Manager, Bazel, Buck2, direnv, mise, just, Docker Compose, process-compose, repo and Terraform.
kind: reference
persona: evaluator
order: 80
verifies:
  commands: [build, shell, exec, run, why, store gc, store copy, home history, home rollback, home apply, home plan, test, graph, clean, daemon stop, shell hook, allow, deny, dev-env export, tasks, up, down, workspace init, sync, workspace pull, workspace status, workspace forall, switch, infra plan, infra apply]
unverified:
  - claim: "Each reprobuild command in the table exists with the arguments shown."
    reason: "scripts/render_command_equivalents.py --check verifies the top-level verb against the dispatcher; subcommands and flags need the CLI model."
    owner: unassigned
---

# Command equivalents

This page lists, for each command of a tool reprobuild replaces, the closest
reprobuild command. A dash means reprobuild has no equivalent. The pages under
[Coming from another tool](../coming-from/index.md) explain the differences.

<!-- generated:begin command-equivalents -->
## Nix

| Nix | reprobuild | Note |
|---|---|---|
| `nix build` | `repro build` |  |
| `nix develop` | `repro shell` |  |
| `nix develop --command <command>` | `repro exec -- <command>` |  |
| `nix run` | `repro run <task>` | Runs a task the project declares, not a package from a registry. |
| `nix why-depends` | `repro why <package-or-action>` |  |
| `nix store gc`, `nix-collect-garbage` | `repro store gc` |  |
| `nix copy` | `repro store copy --to=<store-root>` | Copies to another local store root. |
| `nix profile history` | `repro home history` |  |
| `nix profile rollback` | `repro home rollback` |  |
| `nix search` | — | No package search. |
| `nix repl`, `nix eval` | — | No evaluation console. |

## Home Manager

| Home Manager | reprobuild | Note |
|---|---|---|
| `home-manager switch` | `repro home apply` |  |
| `home-manager build` | `repro home plan` | Shows what an apply would change, without applying it. |
| `home-manager generations` | `repro home history` |  |
| `activating an earlier generation` | `repro home rollback` |  |

## Bazel and Buck2

| Bazel and Buck2 | reprobuild | Note |
|---|---|---|
| `bazel build <target>`, `buck2 build <target>` | `repro build <target>` |  |
| `bazel test`, `buck2 test` | `repro test` |  |
| `bazel run`, `buck2 run` | `repro run <task>` |  |
| `bazel query`, `bazel aquery`, `buck2 uquery` | `repro graph --view=<view>` | Fixed views instead of a query language. |
| `bazel clean` | `repro clean` | Removes the outputs the build owns and keeps the action cache, so the next build restores them from it. |
| `bazel shutdown`, `buck2 kill` | `repro daemon stop` |  |
| `bazel coverage` | — | No coverage command. |

## direnv

| direnv | reprobuild | Note |
|---|---|---|
| `eval "$(direnv hook <shell>)"` | `eval "$(repro shell hook <shell>)"` |  |
| `direnv allow` | `repro allow` |  |
| `direnv deny` | `repro deny` |  |
| `direnv exec <directory> <command>` | `repro exec -- <command>` | Run from inside the directory. |
| `direnv export <shell>` | `repro dev-env export <shell>` |  |

## mise

| mise | reprobuild | Note |
|---|---|---|
| `mise exec -- <command>` | `repro exec -- <command>` |  |
| `mise tasks` | `repro tasks` |  |
| `mise run <task>` | `repro run <task>` |  |

## `just`

| `just` | reprobuild | Note |
|---|---|---|
| `just --list` | `repro tasks` |  |
| `just <recipe>` | `repro run <task>` |  |
| `just <recipe> <arguments>` | `repro run <task> -- <arguments>` |  |

## Docker Compose and process-compose

| Docker Compose and process-compose | reprobuild | Note |
|---|---|---|
| `docker compose up`, `process-compose up` | `repro up` |  |
| `docker compose down`, `process-compose down` | `repro down` |  |

## repo and git submodules

| repo and git submodules | reprobuild | Note |
|---|---|---|
| `repo init` | `repro workspace init <organisation-or-url>` |  |
| `repo sync` | `repro sync` |  |
| `git submodule update` | `repro workspace pull` | Moves every repository to the revision the manifests declare. |
| `repo status` | `repro workspace status` |  |
| `repo forall -c <command>` | `repro workspace forall -c <command>` |  |
| `repo start <branch>` | `repro switch -b <branch>` |  |
| `repo upload` | — | No code-review upload. |

## Terraform and OpenTofu

| Terraform and OpenTofu | reprobuild | Note |
|---|---|---|
| `terraform plan`, `tofu plan` | `repro infra plan` | Resources on the machine that runs repro only. |
| `terraform apply`, `tofu apply` | `repro infra apply` | Resources on the machine that runs repro only. |
| `terraform graph` | `repro graph` |  |
| `terraform import`, `terraform state`, `terraform output` | — | No equivalent. |
<!-- generated:end -->
