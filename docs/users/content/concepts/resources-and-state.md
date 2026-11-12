---
title: Resources and state
description: How a project declares resources of types any repository can define, as Terraform uses providers, and how reprobuild reconciles them, records their state and leases them to the tests that use them.
kind: explanation
persona: build-maintainer
order: 35
verifies:
  commands: [run, reap, reap --once]
  tests:
    - libs/repro_resources/tests/t_resource_provider_lane.nim
    - libs/repro_resources/tests/t_rp4_resource_type_macro.nim
    - tests/integration/t_rp5a_producer_exports_resource_contract_across_workspace.nim
    - tests/integration/t_rp5a_consumer_imports_resource_contract_no_driver.nim
    - tests/integration/t_rp5b_resource_driver_via_protocol.nim
    - libs/repro_resources/tests/t_l1_state_store.nim
    - libs/repro_resources/tests/t_l2_lease_edge.nim
    - tests/integration/t_run_consumes_session_store_out_of_tree.nim
    - tests/integration/t_run_consumes_opaque_out_of_tree.nim
    - libs/repro_resources/tests/t_l3_reaper.nim
    - tests/integration/t_lease_reap_session_transport_is_reachable_from_production.nim
    - tests/integration/t_repro_reap_verb_is_dispatched.nim
    - tests/integration/t_leaked_instance_is_reaped.nim
unverified:
  - claim: "Before a run target or a test runs, reprobuild creates the state groups it consumes, or reuses the resources that already exist, and renews their leases."
    reason: "The cited tests drive the reconcile step that repro run uses, directly; no test runs repro run on a project that consumes a state group."
    owner: unassigned
---

# Resources and state

This page explains how a project declares resources, the parts of its build
graph that are states rather than files, and how reprobuild creates, records,
shares and removes them.

## A resource type is a provider

A resource is something reprobuild creates and keeps in a declared state, such
as a container, a database or a virtual machine. Its type defines the
attributes it takes and how to handle the real object: how to identify it, how
to read its current state, and how to create, change or destroy it. Those are
the operations of a Terraform provider. In reprobuild, any repository can define
them, in Nim, with a `resourceType` declaration in its project file.

A repository's resource types are part of the interface it exports. Another
repository in the workspace can declare resources of those types, with their
attributes checked by the compiler, without copying the type's definition or
linking its code. A type's driver can run inside reprobuild or in a separate
provider program that reprobuild talks to over a protocol.

## Declaring and reconciling resources

A project file declares resources with `resource(...)`, or with the typed
function that a resource type provides, and names what each one depends on with
`dependsOn`. reprobuild reconciles them in dependency order: it reads each
resource's current state, creates, changes or destroys it to match, and records
the result.

Reconciling again when nothing has changed does nothing, because each
resource's desired state has a digest that reprobuild compares with the
recorded one. A resource whose type nobody has defined is an error, never a
silent skip, because its state would otherwise never be reached.

## State is recorded on disk

Each resource reprobuild creates is recorded in a `.repro/state/` directory,
with its type, its attributes and the resources it depends on. The record is
enough to find and destroy the resource later without evaluating the project
file again, so cleaning up does not depend on the project still building.

## Leasing state to the tests that use it

A test that needs a database or a virtual machine does not have to create one
every time. A project groups resources into a named state group with
`stateGroup "name":`, and a run target or a test lists the groups it consumes,
each with a lease policy:

- `immediate()` destroys the state as soon as the consumer finishes.
- `delayed(...)` keeps it for a time after its last use, and every use renews the lease.
- `keep()` never destroys it automatically.

Before the consumer runs, reprobuild creates the group's resources, or reuses
the ones that already exist, and renews the lease.

## The reaper

State whose lease has run out is destroyed by the reaper. It works only from
the records in `.repro/state/`, so it needs neither the project file nor a
running build. The daemon sweeps on a timer, and `repro reap --once` runs one
sweep by hand and reports anything it could not destroy. When a test that holds
a lease is killed before it can clean up, the reaper still destroys what the
test created.

## How this maps onto Terraform

| Terraform or OpenTofu | reprobuild |
|---|---|
| provider | a resource type, declared with `resourceType` |
| `resource` block | `resource(...)`, or a resource type's typed function |
| `depends_on` | `dependsOn` |
| state file | the records in `.repro/state/` |

A system profile's resources, such as systemd units and users, follow the same
model on the machine as a whole;
[Machines and profiles](machines-and-profiles.md) explains them.

## What this does not cover

- reprobuild does not run Terraform or OpenTofu provider binaries. A provider is written as a reprobuild resource type.
- No resource type that ships with reprobuild manages cloud resources.

## Related

- [How reprobuild works](how-reprobuild-works.md)
- [Machines and profiles](machines-and-profiles.md)
- [Tests and certificates](tests-and-certificates.md)
- [Coming from Terraform and OpenTofu](../coming-from/terraform-and-opentofu.md)
- [Glossary: Resource](../reference/glossary.md#resource), [Lease](../reference/glossary.md#lease)
