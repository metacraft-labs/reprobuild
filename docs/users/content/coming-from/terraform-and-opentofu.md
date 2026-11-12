---
title: Coming from Terraform and OpenTofu
description: How Terraform's plan-and-apply model carries over to reprobuild's operating-system profiles and fleets, what works differently, and why Terraform or OpenTofu remains the tool for cloud resources.
kind: explanation
persona: machine-owner
order: 60
verifies:
  commands: [infra plan, infra apply, infra apply --plan, system rollback, home rollback, graph, deploy-agent]
  tests:
    - tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim
    - tests/e2e/m69/t_e2e_repro_infra_depends_on_topological.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim
    - tests/e2e/home-resources/t_integration_prevent_destroy.nim
    - tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim
    - tests/e2e/m69/t_e2e_repro_system_command_family.nim
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - tests/e2e/gm10/t_e2e_infra_apply_refuses_externally_managed_host.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_rejects_wrong_signer.nim
    - libs/repro_resources/tests/t_rp4_resource_type_macro.nim
    - libs/repro_resources/tests/t_resource_provider_lane.nim
unverified:
  - claim: "A profile is Nim, checked by the compiler, and uses the same packages and store as your builds."
    reason: "The home-profile tests compile real profiles; no test is cited for a compile error in a system profile."
    owner: unassigned
---

# Coming from Terraform and OpenTofu

This page explains which parts of Terraform's model carry over to reprobuild,
what reprobuild manages with them, and why Terraform or OpenTofu remains the
tool for cloud resources.

## What carries over

- You declare the state you want, not the steps. A system profile lists resources: a systemd unit, a user, a firewall rule, a registry value.
- Plan, then apply. `repro infra plan` shows the changes; `repro infra apply` makes them, and a new plan afterwards is empty.
- Providers. Any repository can define a resource type, the counterpart of a provider, and projects declare resources of it.
- Resources can depend on each other, and reprobuild applies them in dependency order.
- State is recorded. Each apply records what it manages, so a later apply knows what to change or remove, and what has drifted.

## Concept map

| Terraform or OpenTofu | reprobuild |
|---|---|
| `.tf` configuration | a [system profile](../reference/glossary.md#system-profile), `system.nim`, or a [home profile](../reference/glossary.md#home-profile) |
| provider | a [resource](../reference/glossary.md#resource) type, declared with `resourceType` in any repository |
| resource | a resource in a profile, or one a project declares with `resource(...)` |
| `depends_on` | `depends_on` |
| `terraform plan` | `repro infra plan` |
| a saved plan file | a plan id, applied with `repro infra apply --plan <id>` |
| drift found by refreshing state | the [drift](../reference/glossary.md#drift) report of `repro infra plan` |
| `prevent_destroy` | `lifecyclePolicy = preventDestroy`, in a home profile |
| state file | the recorded [generations](../reference/glossary.md#generation) |
| `terraform graph` | `repro graph` |
| a pipeline that runs `terraform apply` against each environment | [`repro deploy-agent`](../reference/glossary.md#deploy-agent) on each machine |

## What works differently

Each machine applies its own state. `repro infra apply` changes the machine it
runs on. Terraform reaches resources through a provider's API; reprobuild has
each machine in a fleet run `repro deploy-agent`, which fetches a signed manifest
of that machine's profile and applies it. Nothing holds credentials for every
machine. [Fleets and the deploy agent](../concepts/fleets-and-the-deploy-agent.md)
explains the model.

Every apply is a generation you can return to. Applying a changed profile
records a new generation, and `repro system rollback` or `repro home rollback`
returns to an earlier one. Returning to earlier Terraform state means applying
the earlier configuration again.

Drift is reported, then replaced. The plan lists every resource changed outside
reprobuild since the last apply, and the apply puts the profile's state back.
Removing what you no longer declare is part of every apply, and removals that
lose data, such as deleting a user account, need a flag that says you mean it.

The profile is typed code. A profile is Nim, checked by the compiler, and it
uses the same packages and store as your builds. An apply runs through the same
engine as a build, so a step whose result is already in place is not repeated.

## What reprobuild does not do

- It does not run Terraform or OpenTofu provider binaries; a provider is written as a reprobuild resource type.
- No resource type that ships with reprobuild manages cloud resources or creates machines.
- It has no remote state, and no `import` or `state` commands.

## When Terraform or OpenTofu remains the better choice

For cloud resources, managed services and anything reached through a
provider's API, use Terraform or OpenTofu: reprobuild does not manage them. The
two can share the work: Terraform creates the machines, and each machine keeps
its operating system in the declared state with reprobuild.

## Next steps

- [Machines and profiles](../concepts/machines-and-profiles.md)
- [Fleets and the deploy agent](../concepts/fleets-and-the-deploy-agent.md)
- [Resources and state](../concepts/resources-and-state.md)
- [Command equivalents](../reference/command-equivalents.md#terraform-and-opentofu)
