## The Mode B build of a Rust workspace: cargo builds it as a whole through
## the thin cargo edge (`edge`, `edge_cli`), with the selection and profile
## Rust.md § "Mode B" gives (`cargo build --release --locked --offline
## --workspace`).
##
## One constructor, `modeBBuildSpec`, states that edge for both places it is
## declared: the Rust convention's static Mode B fragment, when the
## workspace's static conditions send it to Mode B, and the units edge of a
## workspace built from cargo's plan (`plan_units_edge`), which creates it
## from the graph-production edge when the plan holds a unit the plan's
## edges do not build. So a workspace that falls back at graph production is
## built by exactly the command, inputs and outputs a workspace sent to
## Mode B statically is built by.

import std/os

import repro_build_engine

import ./edge_cli

const
  ModeBBuildArgs* = ["build", "--release", "--locked", "--offline",
                     "--workspace"]
    ## `cargo build`'s arguments in Mode B. `--workspace`: without it cargo
    ## builds only its default members.
  ModeBStatsId* = "standard-provider.crude"

proc modeBProductsFile*(projectRoot, packageName: string): string =
  ## The thin edge's one declared output: the final products cargo reports.
  projectRoot / ".repro" / "build" / "cargo" / (packageName & ".products")

proc modeBBuildSpec*(id, helper, cargo, projectRoot, packageName: string;
                     inputs: openArray[string]): CreatedActionSpec =
  ## The Mode B build edge of the workspace at ``projectRoot`` (absolute):
  ## ``helper`` (the `repro` image that runs the thin edge) running
  ## ``cargo`` with `ModeBBuildArgs`, sized by `-j`, in the `compile` pool,
  ## cacheable and monitored, its declared output the products file.
  ## ``inputs`` are the workspace's files (the crude fallback's input set),
  ## which order and dirty-check it; its key comes from what the monitor
  ## records it reading. `target`, cargo's own incremental state, is neither
  ## an input nor an output.
  result = initCreatedActionSpec(id, edgeCommand(helper,
    modeBProductsFile(projectRoot, packageName), @[cargo] & @ModeBBuildArgs))
  result.cwd = projectRoot
  result.inputs = @inputs
  result.outputs = @[modeBProductsFile(projectRoot, packageName)]
  result.pool = "compile"
  result.widthFlag = "-j"
  result.commandStatsId = ModeBStatsId
  result.cacheable = true
  result.policyKind = CreatedActionAutomaticMonitor
