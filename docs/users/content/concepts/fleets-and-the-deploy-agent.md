---
title: Fleets and the deploy agent
description: How every machine in a fleet keeps the state you declare for it, by fetching a signed manifest and applying it with the same steps as repro infra apply.
kind: explanation
persona: machine-owner
order: 50
verifies:
  commands: [deploy-agent, deploy-agent keygen, deploy-agent compile-profile, infra apply]
  tests:
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim
    - libs/repro_deploy_agent/tests/t_deploy_agent_cli_compiles_manifest_profile.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_rejects_wrong_signer.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_freshness_and_state.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_recipient_keygen.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_materialises_secrets.nim
    - libs/repro_deploy_agent/tests/t_deploy_agent_secret_files_are_private_and_never_follow_links.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_records_tick_history.nim
    - libs/repro_deploy_agent/tests/t_deploy_agent_records_the_resolved_host.nim
unverified:
  - claim: "Manifests can be served from a plain web server or directory that anyone can read."
    reason: "Follows from the signature check, which the cited tests exercise; no test serves manifests from a public web server."
    owner: unassigned
---

# Fleets and the deploy agent

This page explains how reprobuild keeps many machines in the state you declare
for each one, without a controller that logs in to them.

## Each machine pulls its own state

Every machine in the fleet runs `repro deploy-agent` on a timer. Each run fetches
the manifests published for the fleet, takes the one addressed to this machine,
checks it, and applies the state it describes. Nothing connects to the machine to
change it, so no controller holds credentials for every machine.

A manifest names the machine it is for and carries a sequence number. It holds
that machine's system profile together with the build actions the profile needs.
The agent applies it through the same steps as `repro infra apply`, so the
machine reaches the state it would reach if you ran the apply on it yourself, and
the apply is recorded as a generation of the machine.

## The signature carries the trust

The agent applies a manifest only when its signature verifies against a key the
machine trusts, listed in the file named by `--allowed-signers`. A manifest that
another key signed, or that was altered after signing, is refused and changes
nothing. A manifest addressed to another machine is ignored, so one location can
serve the whole fleet.

Because the signature carries the trust, the place manifests are fetched from
does not have to: a plain web server or a directory that anyone can read is
enough.
That is also why nothing in a manifest is confidential unless it is sealed (see
[Secrets](#secrets)).

## Only newer state is applied

The agent records the sequence number of the last manifest it applied, and
applies a manifest only when its sequence is higher. An older or equal manifest,
such as one a stale mirror still serves, changes nothing. A manifest signed with a
time ahead of the machine's clock, or earlier than the last manifest it accepted,
is refused as stale.

## Secrets

A secret travels inside a manifest sealed to the receiving machine's own key.
`repro deploy-agent keygen` creates that key on the machine, prints only its
public half for whoever produces the manifests, and never replaces a key that
already exists. The agent opens the sealed part and writes each secret to disk
before it applies the state that uses it. It writes each file with its declared
permissions from the start and never through a symbolic link. When a sealed part
cannot be opened, the agent applies nothing.

## Producing manifests

`repro deploy-agent compile-profile` compiles a system profile into the form a
manifest carries, for a named host and platform, and applies nothing, so a
producer can prepare manifests for machines other than the one it runs on.
Signing and publishing a manifest is the producer's job: `repro` has no command
for it, and reprobuild's deploy-agent library provides the encoding and the
signature.

## What each run records

The agent records the outcome of every run, as the latest status and as a
history: whether it applied a manifest, found the machine already converged,
found no manifest yet, or refused one, and why. Each generation it applies
records the host name the machine resolved for itself, the same name
`repro home` and `repro infra` use.

## What this does not cover

- `repro` has no command that signs or publishes a manifest.
- The agent changes only the machine it runs on. reprobuild does not log in to machines, and it does not create machines or cloud resources.

## Related

- [Machines and profiles](machines-and-profiles.md)
- [Coming from Terraform and OpenTofu](../coming-from/terraform-and-opentofu.md)
- [Glossary: Deploy agent](../reference/glossary.md#deploy-agent), [Generation](../reference/glossary.md#generation)
