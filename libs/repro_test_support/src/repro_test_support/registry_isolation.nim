## The one place a test names its fake registry hive.
##
## `repro_home_resources/drivers/registry.nim` honours
## `REPRO_REGISTRY_ROOT`: when it is set, every write, delete and read of
## `HKCU` lands in a filesystem-backed fake hive under that directory
## instead of the invoking user's real registry. Every test that applies
## a registry-backed resource -- `env.userPath` (`home.package.<id>.bin`,
## synthesized for any package with executables), `env.userVariable`,
## `windows.startup`, `windows.registryValue` -- must set it, in-process
## or in the environment of the `repro` it spawns. Without it the Windows
## home-apply gates appended their sandbox store prefixes to the real
## `HKCU\Environment\Path` on every run until it outgrew cmd.exe's
## 8191-character limit (reprobuild-pm issue
## `2026-10-23-windows-home-apply-gates-leak-store-prefixes-into-the-real-user-path.md`).
## Under `REPRO_TEST_HOME_FENCE` a forgotten seam fails instead
## (`repro_home_resources/test_home_fence.enforceTestRegistryFence`).
##
## Callers: `registryRootEnv` for a subprocess environment,
## `beginRegistryIsolation` for a whole test (in-process and spawned), the
## `withHomeApplyGuard` fixture for in-process applies, and the m83
## `profile_compile_edge_harness.sandboxEnv` that 40 home gates share.

import std/[os, tempfiles]

const
  RegistryRootEnvVar* = "REPRO_REGISTRY_ROOT"
    ## Spelled here rather than imported from `repro_home_resources` so
    ## the test-support library keeps no dependency on the code under
    ## test; `t_registry_root_override` pins the two spellings together.
  RegistryHiveDirName* = "registry"
    ## The fake hive's directory under a test's scratch root.

proc registryHiveDir*(scratchDir: string): string =
  ## The fake hive a test whose scratch root is `scratchDir` uses.
  scratchDir / RegistryHiveDirName

proc registryRootEnv*(scratchDir: string): tuple[k, v: string] =
  ## Env-var entry that redirects HKCU registry writes made by a
  ## `repro home apply` subprocess into a per-test fake hive under
  ## `scratchDir / "registry"`. Intended use:
  ##
  ## ```nim
  ## let baseEnv = @[
  ##   (k: "REPRO_HOME_STATE_DIR", v: stateDir),
  ##   ...,
  ##   registryRootEnv(tempRoot)]
  ## ```
  (k: RegistryRootEnvVar, v: registryHiveDir(scratchDir))

type RegistryIsolation* = object
  ## A fake hive installed for the current process (and every `repro` it
  ## spawns, which inherit the environment) by `beginRegistryIsolation`.
  hiveRoot*: string
  priorPresent: bool
  priorValue: string

proc beginRegistryIsolation*(label = "repro-registry-"): RegistryIsolation =
  ## Point `REPRO_REGISTRY_ROOT` at a fresh fake hive under the temp dir.
  ## Pair it with `endRegistryIsolation` in a `defer` placed BEFORE the
  ## test's own registry-cleanup `defer`s, so those run (against the fake
  ## hive) first:
  ##
  ## ```nim
  ## let registry = beginRegistryIsolation()
  ## defer: endRegistryIsolation(registry)
  ## ```
  result.priorPresent = existsEnv(RegistryRootEnvVar)
  result.priorValue = getEnv(RegistryRootEnvVar)
  result.hiveRoot = createTempDir(label, "")
  let entry = registryRootEnv(result.hiveRoot)
  putEnv(entry.k, entry.v)

proc endRegistryIsolation*(isolation: RegistryIsolation) =
  ## Restore the prior `REPRO_REGISTRY_ROOT` and remove the fake hive.
  if isolation.priorPresent:
    putEnv(RegistryRootEnvVar, isolation.priorValue)
  else:
    delEnv(RegistryRootEnvVar)
  try:
    removeDir(isolation.hiveRoot)
  except OSError:
    discard
