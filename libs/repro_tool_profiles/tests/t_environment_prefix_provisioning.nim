## Environment-provided library prefixes
## (reprobuild-pm Package-Model.md §"Environment-provided library prefixes",
## approved by Zahary Karadjov, 2026-11-02).
##
## A library's package may declare an `environmentPrefix` arm: the variable
## naming the prefix of an already-installed copy, and the files that make
## the prefix that library. In path mode the engine reads the variable at
## tool resolution, checks the files and the host architecture, and folds
## the files' bytes into the realization's identity at every resolution.
## Under `--target` the arm never applies.
##
## Real files in a real temporary directory and the real path-mode resolver;
## nothing is mocked. The ELF "libraries" are 64-byte headers: what the
## resolver reads of them is the magic and `e_machine`, and their bytes are
## what the identity hashes.
##
## Cases (the spec's tests 1-5; 6 is `repro build .#apps` on reprobuild
## itself, and the engine-level cases are in
## `tests/integration/t_environment_prefix_library.nim`):
##   1. a native path-mode resolution realizes the library from the prefix;
##      an unset variable is refused, naming it;
##   2. a missing header, a missing library and a library of another
##      architecture are each refused, naming the file;
##   3. changing the bytes of a library under an unchanged path changes the
##      realization's identity (so the consuming actions' keys);
##   4. under `--target` the arm is ignored: the sibling's target mirror
##      answers, an unbuilt or missing sibling is refused by name, and a set
##      variable is said to be unused -- the host prefix is never linked;
##   5. nix mode does not consult the arm.

import std/[os, sequtils, strutils, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_project_dsl/install_mirror_resolver
import repro_tool_profiles

const
  Triple = "armv7-unknown-linux-gnueabihf"
  Variable = "ENVPROBE_PREFIX"

package envprobe:
  provisioning:
    environmentPrefix "ENVPROBE_PREFIX", libraries = @["libenvprobe"],
      headers = @["envprobe.h"]

proc withEnv(name, value: string; body: proc()) =
  let had = existsEnv(name)
  let saved = getEnv(name)
  if value.len > 0: putEnv(name, value) else: delEnv(name)
  try: body()
  finally:
    if had: putEnv(name, saved) else: delEnv(name)

proc withTarget(triple: string; body: proc()) =
  withEnv("REPRO_VARIANTS",
    if triple.len > 0: "targetTriple=" & triple else: "", body)

proc hostMachine(): int =
  case hostCPU
  of "amd64": 62
  of "arm64": 183
  of "arm": 40
  of "i386": 3
  else: 62

proc otherMachine(): int =
  ## An `e_machine` that is not the host's.
  if hostMachine() == 40: 62 else: 40

proc elfObject(machine: int; payload = ""): string =
  var head = newString(64)
  head[0] = '\x7f'; head[1] = 'E'; head[2] = 'L'; head[3] = 'F'
  head[4] = '\x02'; head[5] = '\x01'; head[6] = '\x01'
  head[18] = char(machine and 0xff)
  head[19] = char((machine shr 8) and 0xff)
  head & payload

proc armHardFloatObject(): string =
  ## A 32-bit ARM EABI5 hard-float ELF header: what `--target=armv7-...-gnueabihf`
  ## requires of every object in a target mirror (the object check).
  var head = newString(64)
  head[0] = '\x7f'; head[1] = 'E'; head[2] = 'L'; head[3] = 'F'
  head[4] = '\x01'; head[5] = '\x01'; head[6] = '\x01'
  head[18] = char(40)
  head[36] = '\x00'; head[37] = '\x04'; head[38] = '\x00'; head[39] = '\x05'
  head

proc makePrefix(root: string; machine = hostMachine(); payload = "v1";
                header = true; library = true): string =
  result = root / "prefix"
  createDir(result / "lib")
  createDir(result / "include")
  if library:
    writeFile(result / "lib" / "libenvprobe.so.1", elfObject(machine, payload))
    createSymlink("libenvprobe.so.1", result / "lib" / "libenvprobe.so")
  if header:
    writeFile(result / "include" / "envprobe.h", "int envprobe(void);\n")

proc consumer(kind = DepKindTarget): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(projectInterface: toProjectInterface(PackageDef(
    packageName: "envProbeConsumer",
    toolUses: @[PackageUseDef(rawConstraint: "envprobe",
      packageSelector: "envprobe", executableName: "envprobe",
      depKind: kind)]), registeredPackages()))

proc resolveProfile(prefix: string; pathDir = ""): PathOnlyToolProfile =
  var profile: PathOnlyToolProfile
  withEnv(Variable, prefix, proc() =
    profile = pathOnlyBuildIdentity(consumer(), pathDir).profiles[0])
  profile

proc refusalOf(prefix: string; pathDir = ""): string =
  ## The refusal message, or "" when the library resolved.
  var message = ""
  try:
    discard resolveProfile(prefix, pathDir)
  except CatchableError as e:
    message = e.msg
  message

var counter = 0
proc freshTmp(): string =
  inc counter
  result = getTempDir() / ("t_env_prefix_" & $getCurrentProcessId() & "_" &
    $counter)
  createDir(result)

suite "the environmentPrefix provisioning arm":
  test "the package macro records the arm":
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName == "envprobe":
        check pkg.environmentPrefixProvisioning.len == 1
        let arm = pkg.environmentPrefixProvisioning[0]
        check arm.variable == Variable
        check arm.libraries == @["libenvprobe"]
        check arm.headers == @["envprobe.h"]
        found = true
    check found
    # And it travels in the interface the consumer's tool use is built from.
    let uses = consumer().projectInterface.toolUses
    check uses.len == 1
    check uses[0].environmentPrefixProvisioning.len == 1
    check uses[0].environmentPrefixProvisioning[0].variable == Variable

  test "1. a native path-mode resolution realizes the library from the prefix":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp)
    withTarget("", proc() =
      let profile = resolveProfile(prefix)
      check profile.installMethod == "environment-prefix"
      check profile.cpathList == @[prefix / "include"]
      check profile.libraryPathList == @[prefix / "lib"]
      check profile.cmakePrefixList == @[prefix]
      check profile.lockIdentity.startsWith("environment-prefix:" &
        Variable & "=" & prefix))

  test "1. a static archive beside the shared library does not shadow it":
    # nixpkgs' sqlite ships libsqlite3.a next to libsqlite3.so; the linker
    # takes the shared library, so that is the file the identity hashes and
    # the architecture check judges. (A regular file used to be mistaken for a
    # symlink here and refused with "Invalid argument".)
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp, payload = "shared")
    writeFile(prefix / "lib" / "libenvprobe.a", "!<arch>\nstatic")
    withTarget("", proc() =
      let withArchive = resolveProfile(prefix)
      check withArchive.installMethod == "environment-prefix"
      removeFile(prefix / "lib" / "libenvprobe.a")
      let without = resolveProfile(prefix)
      # The archive is not part of the identity: the shared object is.
      check withArchive.lockIdentity == without.lockIdentity)
    # And a prefix that holds ONLY the archive resolves, from the archive.
    removeFile(prefix / "lib" / "libenvprobe.so")
    removeFile(prefix / "lib" / "libenvprobe.so.1")
    writeFile(prefix / "lib" / "libenvprobe.a", "!<arch>\nstatic")
    withTarget("", proc() =
      check resolveProfile(prefix).installMethod == "environment-prefix")

  test "1. an unset variable is refused, naming it":
    withTarget("", proc() =
      let message = refusalOf("")
      checkpoint(message)
      check Variable & " is not set" in message
      check "envprobe" in message)

  test "2. a missing header, a missing library and a missing prefix are refused, naming them":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    withTarget("", proc() =
      let noHeader = refusalOf(makePrefix(tmp, header = false))
      checkpoint(noHeader)
      check "include/envprobe.h" in noHeader
      removeDir(tmp / "prefix")
      let noLibrary = refusalOf(makePrefix(tmp, library = false))
      checkpoint(noLibrary)
      check "holds no libenvprobe" in noLibrary
      let noDir = refusalOf(tmp / "does-not-exist")
      check "is not a directory" in noDir
      check Variable in noDir)

  test "2. a library of another architecture is refused, naming the file":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp, machine = otherMachine())
    withTarget("", proc() =
      let message = refusalOf(prefix)
      checkpoint(message)
      check "libenvprobe.so" in message
      check "not this build host" in message
      check "machine " & $otherMachine() in message)

  test "3. new bytes under an unchanged path change the realization's identity":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp, payload = "version-one")
    withTarget("", proc() =
      let first = resolveProfile(prefix)
      let again = resolveProfile(prefix)
      # Same bytes, same identity: the check is not noise.
      check first.profileFingerprint == again.profileFingerprint
      check first.lockIdentity == again.lockIdentity
      # Same path, same size, other bytes.
      writeFile(prefix / "lib" / "libenvprobe.so.1",
        elfObject(hostMachine(), "version-TWO"))
      let changedLibrary = resolveProfile(prefix)
      check changedLibrary.lockIdentity != first.lockIdentity
      check changedLibrary.profileFingerprint != first.profileFingerprint
      # A header counts too.
      writeFile(prefix / "include" / "envprobe.h", "int envprobe(int);\n")
      let changedHeader = resolveProfile(prefix)
      check changedHeader.profileFingerprint !=
        changedLibrary.profileFingerprint)

  test "3. the resolution signature a cache keys on follows the files":
    # The tool-identity cache key re-runs each use's lookup, not its
    # digesting. For a library that lookup IS the prefix and its files; if
    # the signature ignored them, a cache would serve the first resolution's
    # hashes after the library was replaced.
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp, payload = "version-one")
    let use = consumer().projectInterface.toolUses[0]
    withTarget("", proc() =
      var first, again, changed, refused, other: string
      withEnv(Variable, prefix, proc() =
        first = pathOnlyResolutionSignature(use)
        again = pathOnlyResolutionSignature(use)
        writeFile(prefix / "lib" / "libenvprobe.so.1",
          elfObject(hostMachine(), "version-TWO"))
        changed = pathOnlyResolutionSignature(use)
        removeFile(prefix / "include" / "envprobe.h")
        refused = pathOnlyResolutionSignature(use))
      withEnv(Variable, tmp / "elsewhere", proc() =
        other = pathOnlyResolutionSignature(use))
      check first == again
      check changed != first
      check refused != changed
      check other != changed)
    withTarget(Triple, proc() =
      withEnv(Variable, prefix, proc() =
        check pathOnlyResolutionSignature(use).contains(Triple)))

  test "4. under --target the arm is ignored and the host prefix is never used":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp)
    let recipes = tmp / "packages" / "source"
    let sibling = recipes / "envprobe"
    createDir(sibling)
    writeFile(sibling / "repro.nim", "# the sibling recipe\n")
    withEnv(FromSourceRootEnvVar, recipes, proc() =
      withTarget(Triple, proc() =
        # No sibling build for the target: refused by name, and the set
        # variable is said to be unused -- it is not taken.
        let unbuilt = refusalOf(prefix)
        checkpoint(unbuilt)
        check "has no build for --target" in unbuilt
        check "build its sibling recipe" in unbuilt
        check Variable & " is set, but an environment prefix is the " &
          "build host's library" in unbuilt
        # No sibling recipe at all: refused by name too.
        removeDir(sibling)
        let missing = refusalOf(prefix)
        checkpoint(missing)
        check "cannot be realized for --target" in missing
        check "no source recipe" in missing
        check Variable & " is set" in missing
        # With the variable unset the same refusals stand without the note.
        let unset = refusalOf("")
        check "cannot be realized for --target" in unset
        check Variable notin unset))

  test "4. under --target the sibling's target mirror answers":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let prefix = makePrefix(tmp)
    let recipes = tmp / "packages" / "source"
    let sibling = recipes / "envprobe"
    let mirror = sibling / (".repro/output/install@" & Triple) / "usr"
    createDir(mirror / "lib")
    createDir(mirror / "include")
    writeFile(sibling / "repro.nim", "# the sibling recipe\n")
    writeFile(mirror / "lib" / "libenvprobe.so", armHardFloatObject())
    withEnv(FromSourceRootEnvVar, recipes, proc() =
      withTarget(Triple, proc() =
        # The sidecar a mirror action writes once the mirror passed the
        # object check, in the producer's own spelling.
        let sidecar = realizationInfoPath(recipes, "envprobe")
        createDir(parentDir(sidecar))
        writeFile(sidecar, "platform=" & currentRealizationPlatformTag() &
          "\n")
        let profile = resolveProfile(prefix)
        check profile.installMethod != "environment-prefix"
        for dir in profile.cpathList & profile.libraryPathList &
            profile.cmakePrefixList:
          check not dir.startsWith(prefix)
        check profile.libraryPathList.anyIt(it.contains("install@" & Triple))))

  test "5. nix mode does not consult the arm":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    # A prefix that would be refused outright (another architecture): if the
    # arm were consulted, the refusal would name the variable.
    let prefix = makePrefix(tmp, machine = otherMachine())
    withTarget("", proc() =
      withEnv(Variable, prefix, proc() =
        var message = ""
        try:
          let identity = toolBuildIdentity(consumer(), tpmNix,
            storeRoot = tmp / "tool-store")
          for profile in identity.profiles:
            check profile.installMethod != "environment-prefix"
        except CatchableError as e:
          message = e.msg
        checkpoint(message)
        check Variable notin message
        check "not this build host" notin message))
