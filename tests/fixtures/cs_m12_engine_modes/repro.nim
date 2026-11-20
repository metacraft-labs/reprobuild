## Fixture project of ``tests/integration/test_cs_m12_engine_modes_unchanged.nim``.
##
## It exercises the forms whose engine output the test pins: ``uses:``, a
## ``library``, an ``executable`` with a ``cli:`` section, ``config:`` and a
## ``build:`` body that registers two actions. The test copies
## this directory to a scratch location, so the compile sees it as a project
## outside reprobuild's tree.

import reprobuild
import reprobuild/dsl/packages/sh

const DefaultJobs* = 4

package csm12tool:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "printf"

  config:
    ## Whether the greeting is printed in upper case.
    loud: variant bool = false
    ## The greeting the tool prints.
    greeting: variant string = "hello"

  library csm12greet:
    kind: shared

  executable csm12tool:
    name: "csm12tool"
    cli:
      flag jobs is int, default = DefaultJobs,
        help = "How many jobs to run"
      flag verbose is bool, help = "Print more"
      subcmd "greet", help = "Print the greeting":
        pos who is string, help = "Whom to greet"
      subcmd "count", help = "Count to a number":
        flag upTo is int, default = 3, help = "The last number"

  build:
    let lib = shell(
      command = "mkdir -p build/lib && printf 'lib\\n' > build/lib/libcsm12greet.so",
      actionId = "csm12tool.build.lib",
      extraOutputs = @["build/lib/libcsm12greet.so"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(lib.id, ["mkdir", "printf"])
    let exe = shell(
      command = "mkdir -p build/bin && printf 'exe\\n' > build/bin/csm12tool",
      actionId = "csm12tool.build.exe",
      extraInputs = @["build/lib/libcsm12greet.so"],
      extraOutputs = @["build/bin/csm12tool"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(exe.id, ["mkdir", "printf"])
