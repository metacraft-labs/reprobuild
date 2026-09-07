## Lower a captured foreign environment onto the dev-env DSL verbs.
##
## Split out of `flake.nim` / `envrc.nim` so both activation helpers lower
## through ONE `case`, and so the lowering is the only part of NF-4 that has to
## be `reproProviderMode`-gated. Everything above it — building the `nix` argv,
## running it, diffing the environment, deciding which foreign source wins — is
## ordinary code that compiles and is testable outside a provider binary.

import ./env_capture

import repro_project_dsl

proc applyForeignEnvOps*(ops: openArray[ForeignEnvOp];
                         activities: openArray[string] = []) {.dynOrStatic.} =
  ## Contribute `ops` to the dev environment currently being introspected.
  ##
  ## Outside `reproProviderMode` the dev-env verbs do not exist (they live in
  ## the `when defined(reproProviderMode)` block of
  ## `repro_project_dsl/runtime_core.nim`), and neither does a dev environment
  ## to contribute to — a recipe's `devEnv:` body is only compiled into the
  ## provider binary. So the non-provider arm is a genuine no-op rather than a
  ## fallback that quietly does something else.
  when defined(reproProviderMode):
    for op in ops:
      case op.kind
      of feoSet:
        setEnv(op.name, op.value, activities)
      of feoUnset:
        unsetEnv(op.name, activities)
      of feoPrepend:
        prependPath(op.name, op.value, activities = activities)
      of feoAppend:
        appendPath(op.name, op.value, activities = activities)
  else:
    discard ops
    discard activities
