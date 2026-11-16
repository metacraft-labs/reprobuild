# How Repro Replaces Local Infrastructure Provisioners (Terraform, NixOS, Home Manager)

> **Status:** Conceptual mapping guide for developers and agents managing user-level (`home.nim`) and operating-system (`system.nim`) state profiles.

Reprobuild reconciles user-level environments (`home.nim`) and operating-system or fleet configurations (`system.nim`) as typed, generation-tracked state outputs in the same dependency graph that builds software.

## Conceptual Mapping

| Infrastructure Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **HCL Resources / NixOS & Home Manager modules** | `home.nim` and `system.nim` typed `resources:` / `resourceType` blocks | Compile-time-checked Nim declarations modeling packages, files/symlinks, services, users, mounts, and cloud/Terraform-provider resources. |
| **State File (`.tfstate`) & Generations** | Home & System Generation Databases | Tracks owned live state resources per generation with drift checks and automatic cleanup when declarations are removed. |
| **`terraform plan` (user profile)** | `repro home plan [--profile-dir=PATH] [--host=NAME]` | Previews package, file, and service changes for a `home.nim` profile without mutating the machine. |
| **`terraform apply` (user profile)** | `repro home apply [--profile-dir=PATH] [--host=NAME]` | Materializes and activates a new user-level generation (`repro home rollback` reverts to a prior generation). |
| **`terraform plan` (OS / machine profile)** | `repro infra plan [--profile=PATH] [--host=NAME]` | Computes the desired-state plan and plan ID for a `system.nim` or host infrastructure profile. |
| **`terraform apply` (OS / machine profile)** | `repro infra apply [--plan <id>] [--profile=PATH]` | Applies the planned machine generation (`repro system rollback` reverts to a previous system generation). |
| **Remote bootstrap (`nixos-anywhere`)** | `repro anywhere` / `repro deploy-agent` | Bootstraps target machines over SSH or pulls signed host generations declaratively. |

## Key Commands for Agents

- Always preview before mutating host state:
  - User profile (`home.nim`): `repro home plan` → `repro home apply` (rollback: `repro home rollback`).
  - OS / machine profile (`system.nim`): `repro infra plan` → `repro infra apply --plan <id>` (rollback: `repro system rollback`).
- Inspect generations and provenance: `repro home history`, `repro home why <item>`, `repro system history`, `repro system audit`.
