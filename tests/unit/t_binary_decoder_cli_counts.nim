## Lowered graph records use the production readers directly, without mocks.
include binary_decoder_count_support
include "../../libs/repro_cli_support/src/repro_cli_support.nim"
import std/unittest

proc populatedBuildAction(identity: string): BuildAction =
  ## `populateCountFixture` leaves refs nil, but the cache-entry identity
  ## carries its selected options in a `TableRef`; give it one entry so the
  ## option count is encoded as a populated collection too.
  result = BuildAction(governingLockIdentity: emptySolvedGraphIdentity(identity))
  populateCountFixture(result)
  var entry = result.cacheEntryIdentity.get()
  entry.selectedOptions = newTable[string, string]()
  entry.selectedOptions["option"] = "on"
  result.cacheEntryIdentity = some(entry)

suite "lowered graph bounded count decoding":
  test "populated build action reaches nested dependency and ref counts":
    let action = populatedBuildAction("count-regression")
    var encoded: seq[byte]
    writeBuildAction(encoded, action)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readBuildAction(data, pos), expectedCounts = 26)
  test "outer pool and action counts":
    var value: LoweredGraphCacheRecord
    value.pools = @[BuildPool()]
    value.actions = @[populatedBuildAction("outer-count-regression")]
    checkCountMutations(encodeLoweredGraphCache(value), proc(data: seq[byte]) =
      discard decodeLoweredGraphCache(data), expectedCounts = 28)
