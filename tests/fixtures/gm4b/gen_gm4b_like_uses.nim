## Generates the recipe side of `t_e2e_home_profile_resolves_like_uses`
## (`tests/e2e/gm4b/`): a real recipe module that `uses:` the fixture
## packages, compiled through the real interface extractor
## (`extractInterfaceFromModule`, extraction cache off). Run by edge
## `reprobuild.test_fixtures.gm4b_like_uses` (`repro.nim`) into
## `<output dir>/out/project-interface.rbsz`, which the test reads.
##
## The extraction is a `nim c` of the recipe plus a run of its extract
## runner, minutes cold. It ran at suite scope in every process the test
## runner started for that test; as an edge it runs when what it reads
## changes -- the recipe text below, the fixture module, the DSL.
##
## Usage: gen_gm4b_like_uses <output dir>

import std/os

import repro_interface_artifacts

const
  FixtureModule = currentSourcePath().parentDir().parentDir().parentDir() /
    "e2e" / "gm4b" / "gm4b_contribution_fixture"
  FixturePackages* = ["just", "gh", "jdk", "python3", "7zip", "gm4bcontrib"]
    ## Kept equal to the test's `FixturePackages`; the test's precondition
    ## case checks that every one of them is projected.

when isMainModule:
  if paramCount() != 1:
    quit("usage: gen_gm4b_like_uses <output dir>", 2)
  let outRoot = absolutePath(paramStr(1))
  # The recipe's contribution is the fixture's own; an ambient contributor
  # would rename it.
  delEnv("REPRO_PROVISIONING_CONTRIBUTOR")
  let project = outRoot / "recipe"
  createDir(project)
  var uses = ""
  for p in FixturePackages:
    uses.add("    \"" & p & "\"\n")
  writeFile(project / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/jdk
import repro_dsl_stdlib/packages/pkg_7zip
import """ & "\"" & FixtureModule & "\"" & """


package gm4bResolvesLikeUses:
  defaultToolProvisioning "tarball"
  uses:
""" & uses)
  let artifactPath = outRoot / "out" / "project-interface.rbsz"
  let stubPath = outRoot / "out" / "project-interface.nim"
  createDir(artifactPath.parentDir)
  discard extractInterfaceFromModule(project / "repro.nim",
    artifactPath, stubPath, getCurrentDir(), useExtractionCache = false)
  stdout.writeLine("wrote " & artifactPath)
