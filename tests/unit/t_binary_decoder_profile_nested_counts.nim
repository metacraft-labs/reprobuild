## Exercise all nested profile/probe collections through the real wire readers.
## The readers are private, so the checks live in binary_decoder_profile_fixture
## (see its header for why that is a separate module).
import std/unittest
import ./binary_decoder_profile_fixture

suite "profile nested collection bounds":
  test "populated records roundtrip and every count is bounded":
    check checkProfileNestedCounts()
