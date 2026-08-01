# How Repro Replaces Local Infrastructure Provisioners (Terraform)

> **Status:** Conceptual mapping guide for developers familiar with infrastructure-as-code and configuration deployment.

Reprobuild manages local developer machine configuration (dotfiles, database containers, host packages) using a declarative state model.

## Conceptual Mapping

Reprobuild replaces complex system provisioning scripts and local configuration wrappers with declarative profile rules.

| Infrastructure Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **HCL Resources** (Terraform) | DSL `infra` blocks | Declaratively models local system packages, configuration symlinks, and background services. |
| **State File** (`.tfstate`) | Home Profile Database | Tracks applied files and configurations in a generation database. |
| **`terraform plan`** | `repro infra plan` | Calculates difference between the current system configuration and the DSL definition. |
| **`terraform apply`** | `repro infra apply` | Deploys system packages, writes configuration files, and starts services. |
| **State Rollbacks** | `repro infra rollback` | Instantly rolls back to a previous home profile generation. |

## Key Commands

- `repro infra plan` — plan local environment setup.
- `repro infra apply` — apply declarative changes to the host environment.
- `repro infra rollback` — roll back the local system to a previous generation.
