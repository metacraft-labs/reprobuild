---
title: Coming from another tool
description: Pages that map what you know from Nix, Bazel, direnv, just, repo or Terraform onto reprobuild, including when the other tool remains the better choice.
kind: explanation
persona: evaluator
order: 0
draft: true
---

# Coming from another tool

These pages explain reprobuild in terms of a tool you already know: what carries
over, what works differently and why, what reprobuild does not do, and when the
tool you have is still the better choice.

| You know | Read | Written for |
|---|---|---|
| Nix, flakes, `nix develop` | [Coming from Nix](nix.md) | Build maintainers |
| Bazel, Buck2 | [Coming from Bazel and Buck2](bazel-and-buck2.md) | Build maintainers |
| direnv, devenv, mise, asdf | [Coming from direnv, devenv and mise](direnv-devenv-and-mise.md) | Developers |
| `just`, `make` as a task runner | [Coming from `just` and `make`](just-and-make-tasks.md) | Developers |
| Google's `repo`, git submodules | [Coming from repo and git submodules](repo-and-git-submodules.md) | Workspace maintainers |
| Terraform, OpenTofu | [Coming from Terraform and OpenTofu](terraform-and-opentofu.md) | Machine owners |

Each page links to the guides for moving over. For a command-by-command
lookup, see [Command equivalents](../reference/command-equivalents.md), which is
checked against the commands `repro` has.
