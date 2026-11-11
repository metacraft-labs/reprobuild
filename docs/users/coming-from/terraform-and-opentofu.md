---
title: Coming from Terraform and OpenTofu
description: How the plan-and-apply model carries over to reprobuild's machine configuration, what reprobuild manages today, and why Terraform or OpenTofu remains the tool for cloud resources.
kind: explanation
persona: machine-owner
order: 60
verifies:
  commands: [infra plan, infra apply, system, home]
  tests:
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - tests/e2e/gm10/t_e2e_infra_apply_refuses_externally_managed_host.nim
    - tests/e2e/home-generations/t_integration_pointer_envelope_and_history_enumeration.nim
unverified:
  - claim: "repro infra plan and apply manage resources on the machine that runs repro, such as files, services, users and registry values, and nothing remote."
    reason: "From the infra command documentation; a generated list of resource kinds is needed."
    owner: unassigned
draft: true
---

# Coming from Terraform and OpenTofu

This page explains which parts of Terraform's model carry over to reprobuild,
what reprobuild manages with it today, and why Terraform or OpenTofu remains the
tool for cloud resources.

## What carries over

- **You declare the state you want, not the steps.** A profile describes the
  files, services and settings you want a machine to have.
- **Plan, then apply.** `repro infra plan` shows the difference between the
  declared state and the machine's state; `repro infra apply` makes the change.
- **State is recorded.** Each apply records what it manages, so a later apply
  knows what to change or remove.

## Concept map

| Terraform or OpenTofu | reprobuild |
|---|---|
| `.tf` configuration | a [home profile](../reference/glossary.md#home-profile) or [system profile](../reference/glossary.md#system-profile) |
| `terraform plan` | `repro infra plan` |
| `terraform apply` | `repro infra apply` |
| state file | the profile's recorded [generations](../reference/glossary.md#generation) |
| `terraform graph` | `repro graph` |

## What works differently

**The target is the machine you are on.** `repro infra plan` and
`repro infra apply` manage resources on the machine that runs `repro`: files,
services, users, registry values and similar host resources.

**Every apply is a generation you can return to.** Applying a changed profile
creates a new generation. `repro home rollback` and `repro system rollback`
return to an earlier one.

**The profile is typed code.** A profile is Nim, checked by the compiler, and it
uses the same packages and store as your builds.

## What reprobuild does not do

- It does not manage cloud or remote resources, and it does not run Terraform or
  OpenTofu providers.
- It has no remote state, state locking across machines, `import` or
  `state` commands.

## When Terraform or OpenTofu remains the better choice

For any cloud resource, remote service or infrastructure shared by a team, use
Terraform or OpenTofu: reprobuild does not manage them.

## Next steps

- [Diagnose your setup with `repro health`](../how-to/troubleshooting/diagnose-with-repro-health.md)
- [Command equivalents](../reference/command-equivalents.md#terraform-and-opentofu)
