---
title: Concepts
description: Explanations of how reprobuild works and why it works that way.
kind: explanation
persona: evaluator
order: 0
---

# Concepts

These pages explain how reprobuild works and why. Start with the overview,
which links each stage to the page that covers it.

| Page | Explains |
|---|---|
| [How reprobuild works](how-reprobuild-works.md) | The one graph behind everything reprobuild does, and each stage from a project file to a configured machine |
| [Conventions and the three modes](conventions-and-modes.md) | Why most projects need little or no project file |
| [Dependencies and the store](dependencies-and-the-store.md) | How version ranges become exact versions, and where reprobuild keeps what it obtains |
| [How caching stays correct](how-caching-stays-correct.md) | What reprobuild checks before it reuses a result |
| [Resources and state](resources-and-state.md) | How a project declares resources of types any repository defines, as Terraform uses providers, and leases them to tests |
| [Tests and certificates](tests-and-certificates.md) | How tests run in the build graph, split across machines, and record what passed |
| [Machines and profiles](machines-and-profiles.md) | How a profile describes your account or an operating system, how it is planned and applied, and how a change is rolled back |
| [Fleets and the deploy agent](fleets-and-the-deploy-agent.md) | How every machine in a fleet applies the signed state published for it |
