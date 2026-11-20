## Fixture tools for ``t_cli_env_passthrough_directive``: one per door onto
## the ``envPassthrough`` directive of a ``cli:`` block.
##
## Not named ``t_*`` / ``test_*``, so ``scripts/generate_test_edges.nim`` does
## not register it as a test binary of its own. A separate module from the
## test main for the reason ``m1_fixtures_hook.nim`` gives: the generated
## ``runPackageProvider`` shim of a ``package`` block is guarded by
## ``when isMainModule``.
##
## Each tool declares the directive at the ROOT of its ``cli:`` scope and
## again in a nested ``subcmd`` (repeating one root name), with both
## spellings the directive accepts: string literals and a reference to a
## ``const`` list. The ``plain`` subcommand declares nothing of its own, so
## what it carries is exactly what it inherited.

import repro_project_dsl

const FixtureScratchNames* = ["FIXTURE_SCRATCH_A", "FIXTURE_SCRATCH_B"]
  ## A const list referenced by name from the ``cli:`` blocks below, the way
  ## the ``nim`` tool references ``ScratchLocationEnvNames``.

# The `package … : executable … : cli:` door (`parseCliCommandExtension`).
# No `build:` body, so the typed wrapper records an action
# (`toolActionWrapperCode`).
package `envpassprobe`:
  executable envpassprobe:
    cli:
      envPassthrough "ROOT_SCRATCH"
      subcmd "run":
        envPassthrough "RUN_SCRATCH", "ROOT_SCRATCH"
        envPassthrough FixtureScratchNames, "RUN_SCRATCH"
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        outputs output
      subcmd "plain":
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        outputs output

# The transitional `defineCliInterface` door (`parseInterfaceCommand`).
defineCliInterface envPassIface, "envpass-iface":
  envPassthrough "ROOT_SCRATCH"
  subcmd "run":
    envPassthrough "RUN_SCRATCH", "ROOT_SCRATCH"
    envPassthrough FixtureScratchNames, "RUN_SCRATCH"
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output
  subcmd "plain":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

# A tool that declares nothing: its edges must name nothing.
defineCliInterface envPassSilent, "envpass-silent":
  subcmd "run":
    flag output is string,
      alias = "-o",
      role = output,
      required = true
    outputs output

export envpassprobe
export envPassIface
export envPassSilent
