## A recipe imports a module of a package it declares, by name
## (Test-Certificates.md §"The policy declaration").
##
## A consumer's ``repro.nim`` declares a sibling package with the nested
## ``uses: "certpolicy"`` form and writes ``import team_policy``, a module in
## that package's ``src/``. The engine compiles a consumer's recipe with its
## work directory at reprobuild's own checkout, and it used to read the
## declared packages from THAT directory's recipe, so the consumer's
## declaration never put ``../certpolicy/src`` on the compile and the import
## failed with ``cannot open file: team_policy``. The declared packages now
## come from the recipe being compiled.
##
## The module carries two things the consumer uses: a constant an action of
## the consumer writes to a file, and the branch policy the consumer enacts.
## Through the built ``repro``, nothing mocked:
##
##   1. ``repro build produce`` compiles the recipe (interface extraction and
##      provider compile) and the action writes the module's constant.
##   2. ``repro lock refresh`` succeeds, pins the package, and records the
##      enacted policy -- the certificate-policy enactment path.
##   3. Editing the imported module, uncommitted, rebuilds the recipe: the
##      next ``repro build produce`` writes the NEW constant. A build runs
##      the recipe compiles as monitored edges, so their recorded reads
##      already name the module, and this step holds even without the
##      module in the recipe's source closure (``recipeSourceClosure``). The
##      closure is what protects the compiles that run WITHOUT a monitored
##      edge -- a dev-env activation's in-process extraction, and the
##      provider freshness check a host whose compiler the monitor cannot
##      inject falls back to; the dev-env case is
##      ``tests/e2e/dev-env/t_e2e_dev_env_reextracts_interface_after_lib_source_change.nim``.
##   4. After committing the edit, ``repro lock refresh`` records the edited
##      policy and the moved pin.
##   5. Control: the same recipe with the package named by a BARE ``uses:``
##      string (a tool requirement, not a package declaration) fails the
##      compile on that import. So the import in steps 1-4 resolved through
##      the declaration and through nothing else on the path.
##
## Fixture: ``certificate_policy_fixture.nim`` (real git repositories side by
## side). Skip rule: ``git`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

import ./certificate_policy_fixture

proc policyModule(greeting, agentsMode: string): string =
  ## The body of ``certpolicy/src/team_policy.nim`` after its
  ## ``import repro_certificates``.
  "const sharedGreeting* = \"" & greeting & "\"\n\n" &
    "const teamPolicy* = certificatePolicy \"declared-package\":\n" &
    "  rule \"agents\":\n" &
    "    gateMode " & agentsMode & "\n" &
    "    requires \"t-check\"\n"

proc consumerWith(usesEntry: string): string =
  ## The consumer: imports the module by name, declares (or, in the control,
  ## merely names) the package, enacts the policy, declares ``t-check``, and
  ## has one ``produce`` action writing the module's constant.
  "import std/os\n" &
    "import repro_project_dsl\n" &
    "import team_policy\n\n" &
    "package consumer:\n" &
    "  uses:\n" &
    "    " & usesEntry & "\n" &
    "  enactCertificatePolicy teamPolicy\n" &
    "  build:\n" &
    "    let root = activeProviderProjectRoot()\n" &
    "    let outp = root / \"build\" / \"greeting.txt\"\n" &
    "    createDir(outp.parentDir)\n" &
    "    let produce = buildAction(id = \"produce\",\n" &
    "      call = inlineExecCall(@[\"sh\", \"-c\", \"printf '%s\\\\n' \\\"$1\\\" > \\\"$2\\\"\",\n" &
    "        \"sh\", sharedGreeting, outp], root),\n" &
    "      outputs = @[outp], dependencyPolicy = automaticMonitorPolicy())\n" &
    "    defaultBuildAction(produce)\n" &
    "    let check0 = buildAction(id = \"t-check-check\",\n" &
    "      call = inlineExecCall(@[\"true\"]), cacheable = false)\n" &
    "    certificate \"t-check\", aggregate(\"t-check\", @[check0])\n"

proc build(ws: PolicyWorkspace): PolicyRun =
  ws.reproIn(ws.consumer, "build", "produce", "--tool-provisioning=path",
    "--daemon=off")

proc greeting(ws: PolicyWorkspace): string =
  let path = ws.consumer / "build" / "greeting.txt"
  if fileExists(path): readFile(path).strip() else: ""

suite "a recipe imports a module of a declared package by name":

  test "t_recipe_imports_a_module_of_a_declared_package_by_name":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("declared-package-import",
        policyModule("greeting-v1", "advisory"),
        consumerWith("uses: \"certpolicy\""))
      defer: removeDir(ws.root)

      # (1) The recipe compiles and the action sees the module's constant.
      let first = ws.build()
      checkpoint("first build:\n" & first.output)
      check first.code == 0
      check "cannot open file" notin first.output
      check ws.greeting() == "greeting-v1"

      # (2) The lock refresh compiles the same recipe, pins the package and
      # records the enacted policy.
      let refreshed = ws.refresh()
      checkpoint("first refresh:\n" & refreshed.output)
      check refreshed.code == 0
      let lock1 = lockOf(ws.consumer)
      let pin1 = ws.headOf(ws.policyPkg)
      check ("revision = \"" & pin1 & "\"") in depLine(lock1, "certpolicy")
      check "name = \"declared-package\"" in lock1
      check "package = \"certpolicy\"" in lock1
      check "gate_mode = \"advisory\"" in lock1

      # (3) An uncommitted edit of the imported module re-keys the compiles.
      writeFile(ws.policyPkg / "src" / "team_policy.nim",
        "import repro_certificates\n\n" &
          policyModule("greeting-v2", "required"))
      let second = ws.build()
      checkpoint("build after editing the imported module:\n" & second.output)
      check second.code == 0
      check ws.greeting() == "greeting-v2"

      # (4) Committed, the refresh records the edited policy and the new pin.
      ws.commitAll(ws.policyPkg, "agents required")
      let pin2 = ws.headOf(ws.policyPkg)
      check pin2 != pin1
      let again = ws.refresh()
      checkpoint("refresh after the edit:\n" & again.output)
      check again.code == 0
      let lock2 = lockOf(ws.consumer)
      check ("revision = \"" & pin2 & "\"") in depLine(lock2, "certpolicy")
      check "gate_mode = \"required\"" in lock2
      check "gate_mode = \"advisory\"" notin lock2

      # (5) Control: a bare string names a tool, not a package. The package's
      # directories are then not on the compile, and the import fails there.
      ws.writeConsumer(consumerWith("\"certpolicy\""), "bare uses entry")
      let bare = ws.build()
      checkpoint("build with a bare uses entry:\n" & bare.output)
      check bare.code != 0
      check "team_policy" in bare.output
