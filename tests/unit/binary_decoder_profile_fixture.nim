## Count-mutation checks for the tool-profile wire readers.
##
## The readers and writers are private to repro_tool_profiles, and the count
## recorder in binary_decoder_count_support only sees the writer's u32 fields
## when both are spliced into one module, so this module `include`s them.
## It lives outside the test source because the test-body helper-compilation
## gate follows a test's includes and its heuristic reads the bootstrap
## compiler plumbing elsewhere in repro_tool_profiles as a compiler the test
## spawns. Nothing here runs that code: it only encodes and decodes records
## in memory.
include ./binary_decoder_count_support
include ../../libs/repro_tool_profiles/src/repro_tool_profiles

proc checkProfileNestedCounts*(): bool =
  ## Returns true once every nested count in a populated profile and action
  ## identity has been corrupted and refused; any failure is a doAssert.
  block:
    var profile: PathOnlyToolProfile
    populateCountFixture(profile)
    var encoded: seq[byte]
    writeProfile(encoded, profile)
    var validPos = 0
    let valid = readProfile(encoded, validPos, ArtifactVersion)
    doAssert valid.tarballMirrors.len == 1
    doAssert valid.realizedStorePaths.len == 1
    doAssert valid.probes.len == 1
    doAssert valid.probes[0].spec.args.len == 1
    doAssert valid.libraryPathList.len == 1
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readProfile(data, pos, ArtifactVersion), 9)
  block:
    var identity: ToolActionIdentity
    populateCountFixture(identity)
    var encoded: seq[byte]
    writeActionIdentity(encoded, identity)
    var validPos = 0
    let valid = readActionIdentity(encoded, validPos, ArtifactVersion)
    doAssert valid.tarballMirrors.len == 1
    doAssert valid.realizedStorePaths.len == 1
    doAssert valid.probes.len == 1
    doAssert valid.probes[0].spec.args.len == 1
    doAssert valid.libraryPathList.len == 1
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readActionIdentity(data, pos, ArtifactVersion), 9)
  true
