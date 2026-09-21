## The cross-check material for the launch-digest calculator: an
## independent implementation's published test corpus, and the firmware
## fixtures it computes over.
##
## ## The problem this file exists to solve
##
## A launch-digest calculator is a pure function, and a pure function is
## the easiest thing in the world to test against itself. A gate that
## computed an expected value with the same code it was checking would
## pass every mutation of both halves at once, and it would pass on the
## day the algorithm was wrong in the same way twice. So nothing here is
## produced by the code under test, and nothing here is produced by this
## repository at all.
##
## ## What the corpus is
##
## `virtee/sev-snp-measure` is the reference precomputation tool for this
## measurement — an unrelated implementation, in a different language, by
## a different organisation, published before this one existed. It
## carries a test suite that states, for twenty-odd launch shapes, the
## digest that shape produces. Those statements are the vectors.
##
## `UpstreamMeasureTestsBase64` is that test file, whole and unmodified:
##
##   repository  https://github.com/virtee/sev-snp-measure
##   commit      8f2b337e38bc83f87cd30f3253cdfe8e3e12cc3a
##   path        tests/test_guest.py
##   sha256      801e0f89f2cd6a6f55a1f867e9ad42679336cc9bf1debc24e57d25ac2e3e68f4
##   bytes       18,798
##
## Base64 rather than the text itself, for a reason that is not
## aesthetic: the file contains Python triple-quoted strings, and a Nim
## long string literal ends at the first `"""` it meets, so the text
## cannot be embedded as text without being altered. Altering it is
## exactly what must not happen, so it is carried in a form that cannot
## be altered accidentally and whose digest is stated above. The gate
## decodes it and checks that digest before reading a single vector.
##
## **The vectors are PARSED out of that file, not transcribed from it.**
## This is the load-bearing part. A transcribed table is a table this
## repository wrote, and a typo in it is indistinguishable from a
## calculator that agrees with the typo; worse, a transcriber who copies
## a value from the calculator's own output produces a table that agrees
## with the calculator by construction. The gate reads the upstream
## file's own call sites and its own assertions and builds the table from
## them, so the only way a vector gets in here is by being in the
## upstream file, and the only way one changes is by the upstream file
## changing and its digest failing.
##
## ## What the firmware fixtures are
##
## Two 4,096-byte firmware tails, from the same repository and the same
## commit:
##
##   tests/fixtures/ovmf_AmdSev_suffix.bin
##     sha256 8f765dfabc127fc0a938a0744a3103ec15864d7d794eb4c398aa976b6d6ab16c
##   tests/fixtures/ovmf_OvmfX64_suffix.bin
##     sha256 b4c021e085fb83ceffe6571a3d357b4a98773c83c474e47f76c876708fe316da
##
## Upstream's own README for that directory records what they are: the
## last 4 KiB of two `OVMF.fd` builds from edk2 `edk2-stable202405`, one
## of them the build that supports measuring a directly booted kernel and
## the other the plain one. The tail is all the calculation needs,
## because everything it reads — the identifying table, the list of
## placed pages, the address a second processor starts at — lives in the
## last page, and the two fixtures differ in exactly one respect: the
## first reserves a region for a kernel's digests and the second does
## not. That difference is what makes them a pair worth having rather
## than two copies of one input.
##
## One of these digests is also a vector. `b4c021e0…` is the sha256 of
## the second fixture, and it is also the launch digest upstream states
## for the oldest of the three launch shapes with no kernel — because in
## that shape the digest simply *is* the sha256 of the firmware image.
## The coincidence is real and it is worth noticing rather than
## explaining away: it means one line of the corpus can be checked
## against the fixture with `sha256sum` and nothing else.
##
## ## What this material does NOT establish
##
## **No hardware produced any of it.** These are the outputs of a
## software calculator, checked against the outputs of a different
## software calculator. Two implementations agreeing is a strong
## statement about transcription errors and a weak one about a shared
## misreading of the specification, and nothing here distinguishes the
## two. The vendor's own documents are the only other authority
## consulted, and they were consulted by both implementations.
##
## **This is a conformance check, not an independent derivation.** The
## implementation this corpus checks was written with the reference
## implementation open beside it. The corpus is therefore evidence that
## the port is faithful; it is not evidence that two people who had never
## spoken arrived at the same answer.
##
## **Upstream states that two of its vectors were OBTAINED FROM A LAUNCH
## rather than computed, and they are not here.** Quoted rather than
## paraphrased, because the difference matters: its fixtures README says
## of the supervisor-mode pair that a named hypervisor commit "running
## on host kernel based on commit e1335c6f0 was used to launch Coconut
## SVSM and obtain the measurement values used in the tests", and that
## the supervisor image itself carries "additional code that prints the
## measurement value".
##
## It does not use the word "hardware", and this repository has verified
## none of it. What can be said is narrower and still worth saying: a
## launch measurement can be OBTAINED, as opposed to computed, only from
## a part that produces one — so that pair is the closest thing to a
## vector from real silicon an offline gate can reach. Reproducing it
## needs supervisor mode, a launch shape this build refuses by name, and
## 4.6 MB of further fixtures. The reason it is absent is scope and
## size, not doubt.
##
## ## Mocking
##
## None. Published bytes, carried verbatim.

const
  UpstreamMeasureTestsBase64* =
    "IwojIENvcHlyaWdodCAyMDIyLSBJQk0gSW5jLiBBbGwgcmlnaHRzIHJlc2VydmVkCiMg" &
    "U1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IEFwYWNoZS0yLjAKIwoKaW1wb3J0IHVuaXR0" &
    "ZXN0CmZyb20gc2V2c25wbWVhc3VyZSBpbXBvcnQgZ3Vlc3QKZnJvbSBzZXZzbnBtZWFz" &
    "dXJlIGltcG9ydCB2Y3B1X3R5cGVzCmZyb20gc2V2c25wbWVhc3VyZSBpbXBvcnQgdm1t" &
    "X3R5cGVzCmZyb20gc2V2c25wbWVhc3VyZS5zZXZfbW9kZSBpbXBvcnQgU2V2TW9kZQpp" &
    "bXBvcnQgcGF0aGxpYgppbXBvcnQgdGVtcGZpbGUKaW1wb3J0IGNvbnRleHRsaWIKaW1w" &
    "b3J0IG9zCgoKY2xhc3MgVGVzdEd1ZXN0KHVuaXR0ZXN0LlRlc3RDYXNlKToKCiAgICAj" &
    "IFRlc3Qgb2Ygd2UgY2FuIGdlbmVyYXRlIGEgZ29vZCBPVk1GIGhhc2gKICAgIGRlZiB0" &
    "ZXN0X3NucF9vdm1mX2hhc2hfZ2VuX2RlZmF1bHQoc2VsZik6CiAgICAgICAgb3ZtZl9o" &
    "YXNoID0gJzA4NmUyZTkxNDllYmY0NWFiZGMzNDQ1ZmJhNWIyZGE4MjcwYmRiYjA0MDk0" &
    "ZDdhMmMzN2ZhYWE0YjI0YWYzYWExNmFmZjhjMzc0YzJhNTVjNDY3YTUwZGE2ZDQ2NmI3" &
    "NCcKICAgICAgICBsZCA9IGd1ZXN0LmNhbGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAg" &
    "ICAgICAgIFNldk1vZGUuU0VWX1NOUCwKICAgICAgICAgICAgICAgIDEsCiAgICAgICAg" &
    "ICAgICAgICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAg" &
    "ICAgICAidGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAg" &
    "ICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICIvZGV2L251bGwi" &
    "LAogICAgICAgICAgICAgICAgIiIsCiAgICAgICAgICAgICAgICAweDIxLAogICAgICAg" &
    "ICAgICAgICAgc25wX292bWZfaGFzaF9zdHI9b3ZtZl9oYXNoKQogICAgICAgIHNlbGYu" &
    "YXNzZXJ0RXF1YWwoCiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAg" &
    "ICAgICczMjljOGNlMDk3MmFlNTIzNDNiNjRkMzRhNDM0YTg2ZjI0NWRmZDc0ZjVlZDdh" &
    "YWUnCiAgICAgICAgICAgICAgICAnMTVkMjJlZmM3OGZiOTY4MzYzMmI5YjUwZTRlMWQ3" &
    "ZmE0MTE3OWVmOThhN2VmMTk4JykKCiAgICBkZWYgdGVzdF9zbnBfb3ZtZl9oYXNoX2dl" &
    "bl9mZWF0dXJlX3NucF9vbmx5KHNlbGYpOgogICAgICAgIG92bWZfaGFzaCA9ICcwODZl" &
    "MmU5MTQ5ZWJmNDVhYmRjMzQ0NWZiYTViMmRhODI3MGJkYmIwNDA5NGQ3YTJjMzdmYWFh" &
    "NGIyNGFmM2FhMTZhZmY4YzM3NGMyYTU1YzQ2N2E1MGRhNmQ0NjZiNzQnCiAgICAgICAg" &
    "bGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZN" &
    "b2RlLlNFVl9TTlAsCiAgICAgICAgICAgICAgICAxLAogICAgICAgICAgICAgICAgdmNw" &
    "dV90eXBlcy5DUFVfU0lHU1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRlc3Rz" &
    "L2ZpeHR1cmVzL292bWZfQW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAgICAg" &
    "Ii9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAg" &
    "ICAgICAgICIiLAogICAgICAgICAgICAgICAgMHgxLAogICAgICAgICAgICAgICAgc25w" &
    "X292bWZfaGFzaF9zdHI9b3ZtZl9oYXNoKQogICAgICAgIHNlbGYuYXNzZXJ0RXF1YWwo" &
    "CiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAgICdkZGM1MjI0" &
    "NTIxNjE3YTUzNmVlN2NlOWRkNjIyNGQxYjU4YThkNGZkYTFjNzQxZjMnCiAgICAgICAg" &
    "ICAgICAgICAnYWM5OWZjNGJmYTA0YmE2ZTlmYzk4NjQ2ZDRhMDdhOTA3OTM5N2ZhMzg1" &
    "MjgxOWI1JykKCiAgICAjIFRlc3Qgb2Ygd2UgY2FuIGEgZnVsbCBMRCBmcm9tIHRoZSBP" &
    "Vk1GIGhhc2gKICAgIGRlZiB0ZXN0X3NucF9vdm1mX2hhc2hfZnVsbF9kZWZhdWx0KHNl" &
    "bGYpOgogICAgICAgIG92bWZfaGFzaCA9IGd1ZXN0LmNhbGNfc25wX292bWZfaGFzaCgi" &
    "dGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3VmZml4LmJpbiIpLmhleCgpCiAgICAg" &
    "ICAgc2VsZi5hc3NlcnRFcXVhbCgKICAgICAgICAgICAgICAgIG92bWZfaGFzaCwKICAg" &
    "ICAgICAgICAgICAgICcwODZlMmU5MTQ5ZWJmNDVhYmRjMzQ0NWZiYTViMmRhODI3MGJk" &
    "YmIwNDA5NGQ3YTInCiAgICAgICAgICAgICAgICAnYzM3ZmFhYTRiMjRhZjNhYTE2YWZm" &
    "OGMzNzRjMmE1NWM0NjdhNTBkYTZkNDY2Yjc0JykKCiAgICAgICAgbGQgPSBndWVzdC5j" &
    "YWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFVl9TTlAs" &
    "CiAgICAgICAgICAgICAgICAxLAogICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVf" &
    "U0lHU1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRlc3RzL2ZpeHR1cmVzL292" &
    "bWZfQW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIs" &
    "CiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICJjb25z" &
    "b2xlPXR0eVMwIGxvZ2xldmVsPTciLAogICAgICAgICAgICAgICAgMHgyMSwKICAgICAg" &
    "ICAgICAgICAgIHNucF9vdm1mX2hhc2hfc3RyPW92bWZfaGFzaCkKICAgICAgICBzZWxm" &
    "LmFzc2VydEVxdWFsKAogICAgICAgICAgICAgICAgbGQuaGV4KCksCiAgICAgICAgICAg" &
    "ICAgICAnODAzZjY5MTA5NDk0NmU0MjA2OGFhYTNhOGY5ZTI2YTVjODlmMzZmN2I3M2Vj" &
    "ZmIyJwogICAgICAgICAgICAgICAgJzhjNjUzMzYwZmU0YjNhYmE3ZTUzNDQ0MmU3ZTFl" &
    "MTc4OTVkZmU3NzhkMDIyODk3NycpCgogICAgZGVmIHRlc3Rfc25wX292bWZfaGFzaF9m" &
    "dWxsX2ZlYXR1cmVfc25wX29ubHkoc2VsZik6CiAgICAgICAgb3ZtZl9oYXNoID0gZ3Vl" &
    "c3QuY2FsY19zbnBfb3ZtZl9oYXNoKCJ0ZXN0cy9maXh0dXJlcy9vdm1mX0FtZFNldl9z" &
    "dWZmaXguYmluIikuaGV4KCkKICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAg" &
    "ICAgICAgICAgb3ZtZl9oYXNoLAogICAgICAgICAgICAgICAgJzA4NmUyZTkxNDllYmY0" &
    "NWFiZGMzNDQ1ZmJhNWIyZGE4MjcwYmRiYjA0MDk0ZDdhMicKICAgICAgICAgICAgICAg" &
    "ICdjMzdmYWFhNGIyNGFmM2FhMTZhZmY4YzM3NGMyYTU1YzQ2N2E1MGRhNmQ0NjZiNzQn" &
    "KQoKICAgICAgICBsZCA9IGd1ZXN0LmNhbGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAg" &
    "ICAgICAgIFNldk1vZGUuU0VWX1NOUCwKICAgICAgICAgICAgICAgIDEsCiAgICAgICAg" &
    "ICAgICAgICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAg" &
    "ICAgICAidGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAg" &
    "ICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICIvZGV2L251bGwi" &
    "LAogICAgICAgICAgICAgICAgImNvbnNvbGU9dHR5UzAgbG9nbGV2ZWw9NyIsCiAgICAg" &
    "ICAgICAgICAgICAweDEsCiAgICAgICAgICAgICAgICBzbnBfb3ZtZl9oYXNoX3N0cj1v" &
    "dm1mX2hhc2gpCiAgICAgICAgc2VsZi5hc3NlcnRFcXVhbCgKICAgICAgICAgICAgICAg" &
    "IGxkLmhleCgpLAogICAgICAgICAgICAgICAgJzZkMjg3ODEzZWI1MjIyZDc3MGY3NTAw" &
    "NWM2NjRlMzRjMjA0ZjM4NWNlODMyY2MyYycKICAgICAgICAgICAgICAgICdlN2QwZDZm" &
    "MzU0NDU0MzYyZjM5MGVmODNhOTIwNDZjMDQyZTcwNjM2M2I0YjA4ZmEnKQoKICAgIGRl" &
    "ZiB0ZXN0X3NucF9lYzJfZGVmYXVsdChzZWxmKToKICAgICAgICBsZCA9IGd1ZXN0LmNh" &
    "bGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAgICAgICAgIFNldk1vZGUuU0VWX1NOUCwK" &
    "ICAgICAgICAgICAgICAgIDEsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQVV9T" &
    "SUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAgICAidGVzdHMvZml4dHVyZXMvb3Zt" &
    "Zl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwK" &
    "ICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAgICAgICAgICAgICAgIiIsCiAg" &
    "ICAgICAgICAgICAgICAweDIxLAogICAgICAgICAgICAgICAgdm1tX3R5cGU9dm1tX3R5" &
    "cGVzLlZNTVR5cGUuZWMyKQogICAgICAgIHNlbGYuYXNzZXJ0RXF1YWwoCiAgICAgICAg" &
    "ICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAgICcwY2U5Y2NjMDZiYWI1NWVl" &
    "YmU4YWJjMjM0ZjNkZjY1MTQ4ODM5NzdhNjhhNTkxYjcnCiAgICAgICAgICAgICAgICAn" &
    "MTA1MjQ5OGFiNTJiMmYxYWE0MTVkYjMzODAzMzk0NmVmOTNhYTgyNzhjMGQ2N2ZiJykK" &
    "CiAgICBkZWYgdGVzdF9zbnBfZWMyX2ZlYXR1cmVfc25wX29ubHkoc2VsZik6CiAgICAg" &
    "ICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBT" &
    "ZXZNb2RlLlNFVl9TTlAsCiAgICAgICAgICAgICAgICAxLAogICAgICAgICAgICAgICAg" &
    "dmNwdV90eXBlcy5DUFVfU0lHU1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRl" &
    "c3RzL2ZpeHR1cmVzL292bWZfQW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAg" &
    "ICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAg" &
    "ICAgICAgICAgICIiLAogICAgICAgICAgICAgICAgMHgxLAogICAgICAgICAgICAgICAg" &
    "dm1tX3R5cGU9dm1tX3R5cGVzLlZNTVR5cGUuZWMyKQogICAgICAgIHNlbGYuYXNzZXJ0" &
    "RXF1YWwoCiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAgICcw" &
    "ODgzYmQwZWViNzE2ZTY1YjdiOTc3YTMyMWMyNzhkMWU1MWIzM2I1YzY1NWZhYjknCiAg" &
    "ICAgICAgICAgICAgICAnODU0NDNiYmNjNjVjMDg2YjljMTVlOGEwYmQ4ODExMDUwZGVj" &
    "N2UyNDk2NGU1MDU2JykKCiAgICBkZWYgdGVzdF9zbnBfZ2NlX2RlZmF1bHQoc2VsZik6" &
    "CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAg" &
    "ICAgICBTZXZNb2RlLlNFVl9TTlAsCiAgICAgICAgICAgICAgICAxLAogICAgICAgICAg" &
    "ICAgICAgTm9uZSwKICAgICAgICAgICAgICAgICJ0ZXN0cy9maXh0dXJlcy9vdm1mX0Ft" &
    "ZFNldl9zdWZmaXguYmluIiwKICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAg" &
    "ICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAiIiwKICAgICAg" &
    "ICAgICAgICAgIDB4MSwKICAgICAgICAgICAgICAgIHZtbV90eXBlPXZtbV90eXBlcy5W" &
    "TU1UeXBlLmdjZSkKICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAgICAg" &
    "ICAgbGQuaGV4KCksCiAgICAgICAgICAgICAgICAnNWRhNzEwNmNmMTRjZjQ2YjE3MjVl" &
    "YmFiMTIzZWI5ZTUzYmQ0NmExZTlmNDAwY2QwJwogICAgICAgICAgICAgICAgJ2MwOGU3" &
    "ODI3YjA0YjY4OGVhOGI0ZTQwM2M4NDA0ZWZlZDQzOTdlYTVkNWQwNzIyZScpCgogICAg" &
    "ZGVmIHRlc3Rfc25wX2djZV93aXRoX211bHRpcGxlX3ZjcHVzX2RlZmF1bHQoc2VsZik6" &
    "CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAg" &
    "ICAgICBTZXZNb2RlLlNFVl9TTlAsCiAgICAgICAgICAgICAgICA0LAogICAgICAgICAg" &
    "ICAgICAgTm9uZSwKICAgICAgICAgICAgICAgICJ0ZXN0cy9maXh0dXJlcy9vdm1mX0Ft" &
    "ZFNldl9zdWZmaXguYmluIiwKICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAg" &
    "ICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAiIiwKICAgICAg" &
    "ICAgICAgICAgIDB4MSwKICAgICAgICAgICAgICAgIHZtbV90eXBlPXZtbV90eXBlcy5W" &
    "TU1UeXBlLmdjZSkKICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAgICAg" &
    "ICAgbGQuaGV4KCksCiAgICAgICAgICAgICAgICAnNWM1ZGViZjEwMGZjMzM5ZjkwMjc2" &
    "ZTc2MWVlMWYxNjU4ZDA4OTIyYzNiMjBlMmEyJwogICAgICAgICAgICAgICAgJ2U2Yzdh" &
    "NmMzMzcwYjI0NTJhMTVhMDBlYWUxMTg4NmE5M2Q2ZmQxZTdhYjgxZTI5ZCcpCgogICAg" &
    "ZGVmIHRlc3Rfc25wX2RlZmF1bHQoc2VsZik6CiAgICAgICAgbGQgPSBndWVzdC5jYWxj" &
    "X2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFVl9TTlAsCiAg" &
    "ICAgICAgICAgICAgICAxLAogICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVfU0lH" &
    "U1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRlc3RzL2ZpeHR1cmVzL292bWZf" &
    "QW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAg" &
    "ICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICJjb25zb2xl" &
    "PXR0eVMwIGxvZ2xldmVsPTciLAogICAgICAgICAgICAgICAgMHgyMSkKICAgICAgICBz" &
    "ZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAgICAgICAgbGQuaGV4KCksCiAgICAgICAg" &
    "ICAgICAgICAnODAzZjY5MTA5NDk0NmU0MjA2OGFhYTNhOGY5ZTI2YTVjODlmMzZmN2I3" &
    "M2VjZmIyJwogICAgICAgICAgICAgICAgJzhjNjUzMzYwZmU0YjNhYmE3ZTUzNDQ0MmU3" &
    "ZTFlMTc4OTVkZmU3NzhkMDIyODk3NycpCgogICAgZGVmIHRlc3Rfc25wX2d1ZXN0X2Zl" &
    "YXR1cmVfc25wX29ubHkoc2VsZik6CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xhdW5j" &
    "aF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFVl9TTlAsCiAgICAgICAg" &
    "ICAgICAgICAxLAogICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVfU0lHU1siRVBZ" &
    "Qy12NCJdLAogICAgICAgICAgICAgICAgInRlc3RzL2ZpeHR1cmVzL292bWZfQW1kU2V2" &
    "X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAg" &
    "ICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICJjb25zb2xlPXR0eVMw" &
    "IGxvZ2xldmVsPTciLAogICAgICAgICAgICAgICAgMHgxKQogICAgICAgIHNlbGYuYXNz" &
    "ZXJ0RXF1YWwoCiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAg" &
    "ICc2ZDI4NzgxM2ViNTIyMmQ3NzBmNzUwMDVjNjY0ZTM0YzIwNGYzODVjZTgzMmNjMmMn" &
    "CiAgICAgICAgICAgICAgICAnZTdkMGQ2ZjM1NDQ1NDM2MmYzOTBlZjgzYTkyMDQ2YzA0" &
    "MmU3MDYzNjNiNGIwOGZhJykKCiAgICBkZWYgdGVzdF9zbnBfd2l0aG91dF9rZXJuZWxf" &
    "ZGVmYXVsdChzZWxmKToKICAgICAgICBsZCA9IGd1ZXN0LmNhbGNfbGF1bmNoX2RpZ2Vz" &
    "dCgKICAgICAgICAgICAgICAgIFNldk1vZGUuU0VWX1NOUCwKICAgICAgICAgICAgICAg" &
    "IDEsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0Il0s" &
    "CiAgICAgICAgICAgICAgICAidGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3VmZml4" &
    "LmJpbiIsCiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgTm9uZSwK" &
    "ICAgICAgICAgICAgICAgIE5vbmUsCiAgICAgICAgICAgICAgICAweDIxKQogICAgICAg" &
    "IHNlbGYuYXNzZXJ0RXF1YWwoCiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAg" &
    "ICAgICAgICAgICdlMWUxY2EwMjlkZDc5NzNhYjk1MTMyOTViZTY4MTk4NDcyZGNkNGZj" &
    "ODM0YmQ5YWYnCiAgICAgICAgICAgICAgICAnOWI2M2Y2ZThhMTY3NGRiZjI4MWE5Mjc4" &
    "YTRhMmViZTBlZWQ5ZjIyYWRiY2QwZTJiJykKCiAgICBkZWYgdGVzdF9zbnBfd2l0aG91" &
    "dF9rZXJuZWxfZmVhdHVyZV9zbnBfb25seShzZWxmKToKICAgICAgICBsZCA9IGd1ZXN0" &
    "LmNhbGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAgICAgICAgIFNldk1vZGUuU0VWX1NO" &
    "UCwKICAgICAgICAgICAgICAgIDEsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQ" &
    "VV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAgICAidGVzdHMvZml4dHVyZXMv" &
    "b3ZtZl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICBOb25lLAogICAg" &
    "ICAgICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAgIE5vbmUsCiAgICAgICAgICAg" &
    "ICAgICAweDEpCiAgICAgICAgc2VsZi5hc3NlcnRFcXVhbCgKICAgICAgICAgICAgICAg" &
    "IGxkLmhleCgpLAogICAgICAgICAgICAgICAgJzE5MzU4YmE5YTc2MTU1MzRhOWExZTJm" &
    "MGRmYzI5Mzg0ZGNkNGRjYjcwNjJmZjljNicKICAgICAgICAgICAgICAgICcwMTNiMjY4" &
    "NjlhNWZjNmVjYWJlMDMzYzQ4ZGQ2ZjZkYjVkNmQ3NmU3YzVkZjYzMmQnKQoKICAgIGRl" &
    "ZiB0ZXN0X3NucF93aXRoX211bHRpcGxlX3ZjcHVzX2RlZmF1bHQoc2VsZik6CiAgICAg" &
    "ICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBT" &
    "ZXZNb2RlLlNFVl9TTlAsCiAgICAgICAgICAgICAgICA0LAogICAgICAgICAgICAgICAg" &
    "dmNwdV90eXBlcy5DUFVfU0lHU1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRl" &
    "c3RzL2ZpeHR1cmVzL292bWZfQW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAg" &
    "ICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAg" &
    "ICAgICAgICAgICIiLAogICAgICAgICAgICAgICAgMHgyMSkKICAgICAgICBzZWxmLmFz" &
    "c2VydEVxdWFsKAogICAgICAgICAgICAgICAgbGQuaGV4KCksCiAgICAgICAgICAgICAg" &
    "ICAnNDk1M2IxZmI0MTZmYTg3NDk4MGU4NDQyYjM3MDZkMzQ1OTI2ZDVmMzg4NzkxMzRl" &
    "JwogICAgICAgICAgICAgICAgJzAwODEzYzVkN2FiY2JlNzhlYWZlN2I0MjI5MDdiZTBi" &
    "NDY5OGUyNDE0YTYzMTk0MicpCgogICAgZGVmIHRlc3Rfc25wX3dpdGhfbXVsdGlwbGVf" &
    "dmNwdXNfZmVhdHVyZV9zbnBfb25seShzZWxmKToKICAgICAgICBsZCA9IGd1ZXN0LmNh" &
    "bGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAgICAgICAgIFNldk1vZGUuU0VWX1NOUCwK" &
    "ICAgICAgICAgICAgICAgIDQsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQVV9T" &
    "SUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAgICAidGVzdHMvZml4dHVyZXMvb3Zt" &
    "Zl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwK" &
    "ICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAgICAgICAgICAgICAgIiIsCiAg" &
    "ICAgICAgICAgICAgICAweDEpCiAgICAgICAgc2VsZi5hc3NlcnRFcXVhbCgKICAgICAg" &
    "ICAgICAgICAgIGxkLmhleCgpLAogICAgICAgICAgICAgICAgJzUwNjFmZmZiMDE5NDkz" &
    "YTkwMzYxM2Q1NmQ1NGI5NDkxMmExYTJmOWU0NTAyMzg1ZicKICAgICAgICAgICAgICAg" &
    "ICc1YzE5NDYxNjc1MzcyMGE5MjQ0MTMxMGJhNmM0OTMzZGU4NzdjMzZlMjMwNDZhZDUn" &
    "KQoKICAgIGRlZiB0ZXN0X3NucF93aXRoX292bWZ4NjRfd2l0aG91dF9kZWZhdWx0KHNl" &
    "bGYpOgogICAgICAgIGxkID0gZ3Vlc3QuY2FsY19sYXVuY2hfZGlnZXN0KAogICAgICAg" &
    "ICAgICAgICAgU2V2TW9kZS5TRVZfU05QLAogICAgICAgICAgICAgICAgMSwKICAgICAg" &
    "ICAgICAgICAgIHZjcHVfdHlwZXMuQ1BVX1NJR1NbIkVQWUMtdjQiXSwKICAgICAgICAg" &
    "ICAgICAgICJ0ZXN0cy9maXh0dXJlcy9vdm1mX092bWZYNjRfc3VmZml4LmJpbiIsCiAg" &
    "ICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAg" &
    "ICAgICAgIE5vbmUsCiAgICAgICAgICAgICAgICAweDIxKQogICAgICAgIHNlbGYuYXNz" &
    "ZXJ0RXF1YWwoCiAgICAgICAgICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAg" &
    "ICcyODc5N2FlMGFmYWJhNDAwNWE4MWU2MjlhY2ViZmI1OWU2Njg3OTQ5ZDZiZTQ0MDAn" &
    "CiAgICAgICAgICAgICAgICAnN2NkNTUwNjgyM2IwZGQ2NmYxNDZhYWFlMjZmZjI5MWVl" &
    "ZDdiNDkzZDhhNjRjMzg1JykKCiAgICBkZWYgdGVzdF9zbnBfd2l0aF9vdm1meDY0X3dp" &
    "dGhvdXRfa2VybmVsX2ZlYXR1cmVfc25wX29ubHkoc2VsZik6CiAgICAgICAgbGQgPSBn" &
    "dWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNF" &
    "Vl9TTlAsCiAgICAgICAgICAgICAgICAxLAogICAgICAgICAgICAgICAgdmNwdV90eXBl" &
    "cy5DUFVfU0lHU1siRVBZQy12NCJdLAogICAgICAgICAgICAgICAgInRlc3RzL2ZpeHR1" &
    "cmVzL292bWZfT3ZtZlg2NF9zdWZmaXguYmluIiwKICAgICAgICAgICAgICAgIE5vbmUs" &
    "CiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAg" &
    "ICAgICAgICAgIDB4MSkKICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAg" &
    "ICAgICAgbGQuaGV4KCksCiAgICAgICAgICAgICAgICAnZGEwMjk2ZGU4MTkzNTg2YTU1" &
    "MTIwNzhkY2Q3MTllY2NlY2JkODdlMmI4MjVhZDQxJwogICAgICAgICAgICAgICAgJzQ4" &
    "YzQ0ZjY2NWRjODdkZjIxZTViNDllMjE1MjNhOWFkOTkzYWZkYjZhMzBiNDAwNScpCgog" &
    "ICAgZGVmIHRlc3Rfc25wX3dpdGhfb3ZtZng2NF9hbmRfa2VybmVsX3Nob3VsZF9mYWls" &
    "KHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5hc3NlcnRSYWlzZXMoUnVudGltZUVycm9y" &
    "KSBhcyBjOgogICAgICAgICAgICBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAg" &
    "ICAgICAgICAgICAgICAgU2V2TW9kZS5TRVZfU05QLAogICAgICAgICAgICAgICAgICAg" &
    "IDEsCiAgICAgICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVfU0lHU1siRVBZQy12" &
    "NCJdLAogICAgICAgICAgICAgICAgICAgICJ0ZXN0cy9maXh0dXJlcy9vdm1mX092bWZY" &
    "NjRfc3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAg" &
    "ICAgICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAgICAg" &
    "IiIsCiAgICAgICAgICAgICAgICAgICAgMHgyMSkKICAgICAgICBzZWxmLmFzc2VydEVx" &
    "dWFsKHN0cihjLmV4Y2VwdGlvbiksCiAgICAgICAgICAgICAgICAgICAgICAgICAiS2Vy" &
    "bmVsIHNwZWNpZmllZCBidXQgT1ZNRiBtZXRhZGF0YSBkb2Vzbid0IGluY2x1ZGUgU05Q" &
    "X0tFUk5FTF9IQVNIRVMgc2VjdGlvbiIpCgogICAgZGVmIHRlc3Rfc2V2ZXMoc2VsZik6" &
    "CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAg" &
    "ICAgICBTZXZNb2RlLlNFVl9FUywKICAgICAgICAgICAgICAgIDEsCiAgICAgICAgICAg" &
    "ICAgICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAg" &
    "ICAidGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3VmZml4LmJpbiIsCiAgICAgICAg" &
    "ICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAog" &
    "ICAgICAgICAgICAgICAgIiIsCiAgICAgICAgICAgICAgICAweDEpCiAgICAgICAgc2Vs" &
    "Zi5hc3NlcnRFcXVhbCgKICAgICAgICAgICAgICAgIGxkLmhleCgpLAogICAgICAgICAg" &
    "ICAgICAgJzEzODEwYWU2NjFlYTExZTJiYjIwNTYyMWY1ODJmZWUyNjhmMDM2N2M4Zjk3" &
    "YmMyOTdiN2ZhZGVmM2UxMjAwMmMnKQoKICAgIGRlZiB0ZXN0X3NldmVzX3dpdGhfbXVs" &
    "dGlwbGVfdmNwdXMoc2VsZik6CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9k" &
    "aWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFVl9FUywKICAgICAgICAgICAg" &
    "ICAgIDQsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0" &
    "Il0sCiAgICAgICAgICAgICAgICAidGVzdHMvZml4dHVyZXMvb3ZtZl9BbWRTZXZfc3Vm" &
    "Zml4LmJpbiIsCiAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAg" &
    "ICAgICIvZGV2L251bGwiLAogICAgICAgICAgICAgICAgIiIsCiAgICAgICAgICAgICAg" &
    "ICAweDIxKQogICAgICAgIHNlbGYuYXNzZXJ0RXF1YWwoCiAgICAgICAgICAgICAgICBs" &
    "ZC5oZXgoKSwKICAgICAgICAgICAgICAgICcwZGNjYmNhYmE4ZTkwYjI2MWJkMGQyZTE4" &
    "NjNhMmY5ZGE3MTQ3NjhiN2IyYTE5MzYzY2Q2YWUzNWFhOTBkZTkxJykKCiAgICBkZWYg" &
    "dGVzdF9zZXZlc19kdW1wX3Ztc2Eoc2VsZik6CiAgICAgICAgIiIiVGVzdCB0aGF0IFNF" &
    "Vi1FUyBtb2RlIGNyZWF0ZXMgdm1zYSBmaWxlcyBpZiByZXF1cmVzdGVkLiIiIgogICAg" &
    "ICAgIGZpeHR1cmVzX2RpciA9IHBhdGhsaWIuUGF0aCgndGVzdHMvZml4dHVyZXMnKS5h" &
    "YnNvbHV0ZSgpCiAgICAgICAgd2l0aCB0ZW1wZmlsZS5UZW1wb3JhcnlEaXJlY3Rvcnko" &
    "KSBhcyB0bXA6CiAgICAgICAgICAgIHdpdGggcHVzaF9kaXIodG1wKToKICAgICAgICAg" &
    "ICAgICAgIGd1ZXN0LmNhbGNfbGF1bmNoX2RpZ2VzdCgKICAgICAgICAgICAgICAgICAg" &
    "ICAgICAgU2V2TW9kZS5TRVZfRVMsCiAgICAgICAgICAgICAgICAgICAgICAgIDQsCiAg" &
    "ICAgICAgICAgICAgICAgICAgICAgIHZjcHVfdHlwZXMuQ1BVX1NJR1NbIkVQWUMtdjQi" &
    "XSwKICAgICAgICAgICAgICAgICAgICAgICAgZml4dHVyZXNfZGlyIC8gIm92bWZfQW1k" &
    "U2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAgICAgICAgICAgICAiL2Rldi9udWxs" &
    "IiwKICAgICAgICAgICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAg" &
    "ICAgICAgICAgICAgICIiLAogICAgICAgICAgICAgICAgICAgICAgICAweDIxLAogICAg" &
    "ICAgICAgICAgICAgICAgICAgICBkdW1wX3Ztc2E9VHJ1ZSkKICAgICAgICAgICAgICAg" &
    "IHNlbGYuYXNzZXJ0VHJ1ZShwYXRobGliLlBhdGgoInZtc2EwLmJpbiIpLmV4aXN0cygp" &
    "KQogICAgICAgICAgICAgICAgc2VsZi5hc3NlcnRUcnVlKHBhdGhsaWIuUGF0aCgidm1z" &
    "YTEuYmluIikuZXhpc3RzKCkpCiAgICAgICAgICAgICAgICBzZWxmLmFzc2VydFRydWUo" &
    "cGF0aGxpYi5QYXRoKCJ2bXNhMi5iaW4iKS5leGlzdHMoKSkKICAgICAgICAgICAgICAg" &
    "IHNlbGYuYXNzZXJ0VHJ1ZShwYXRobGliLlBhdGgoInZtc2EzLmJpbiIpLmV4aXN0cygp" &
    "KQogICAgICAgICAgICAgICAgc2VsZi5hc3NlcnRGYWxzZShwYXRobGliLlBhdGgoInZt" &
    "c2E0LmJpbiIpLmV4aXN0cygpKQoKICAgIGRlZiB0ZXN0X3NldmVzX3dpdGhfb3ZtZng2" &
    "NF9hbmRfa2VybmVsX3Nob3VsZF9mYWlsKHNlbGYpOgogICAgICAgIHdpdGggc2VsZi5h" &
    "c3NlcnRSYWlzZXMoUnVudGltZUVycm9yKSBhcyBjOgogICAgICAgICAgICBndWVzdC5j" &
    "YWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICAgICAgU2V2TW9kZS5TRVZf" &
    "RVMsCiAgICAgICAgICAgICAgICAgICAgMSwKICAgICAgICAgICAgICAgICAgICBOb25l" &
    "LAogICAgICAgICAgICAgICAgICAgICJ0ZXN0cy9maXh0dXJlcy9vdm1mX092bWZYNjRf" &
    "c3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAg" &
    "ICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICAgICAgIiIs" &
    "CiAgICAgICAgICAgICAgICAgICAgMHgyMSkKICAgICAgICBzZWxmLmFzc2VydEVxdWFs" &
    "KHN0cihjLmV4Y2VwdGlvbiksCiAgICAgICAgICAgICAgICAgICAgICAgICAiS2VybmVs" &
    "IHNwZWNpZmllZCBidXQgT1ZNRiBkb2Vzbid0IHN1cHBvcnQga2VybmVsL2luaXRyZC9j" &
    "bWRsaW5lIG1lYXN1cmVtZW50IikKCiAgICBkZWYgdGVzdF9zZXYoc2VsZik6CiAgICAg" &
    "ICAgbGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBT" &
    "ZXZNb2RlLlNFViwKICAgICAgICAgICAgICAgIDEsCiAgICAgICAgICAgICAgICBOb25l" &
    "LAogICAgICAgICAgICAgICAgInRlc3RzL2ZpeHR1cmVzL292bWZfQW1kU2V2X3N1ZmZp" &
    "eC5iaW4iLAogICAgICAgICAgICAgICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAg" &
    "ICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICJjb25zb2xlPXR0eVMwIGxvZ2xl" &
    "dmVsPTciLAogICAgICAgICAgICAgICAgMHgyMSkKICAgICAgICBzZWxmLmFzc2VydEVx" &
    "dWFsKAogICAgICAgICAgICAgICAgbGQuaGV4KCksCiAgICAgICAgICAgICAgICAnODJh" &
    "M2VlNWQ1MzdjMzYyMDYyODI3MGMyOTJhZTMwY2I0MGMzYzg3ODY2NmE3ODkwZWU3ZWYy" &
    "YTA4ZmI1MzVmZicpCgogICAgZGVmIHRlc3Rfc2V2X3dpdGhfa2VybmVsX3dpdGhvdXRf" &
    "aW5pdHJkX2FuZF9hcHBlbmQoc2VsZik6CiAgICAgICAgbGQgPSBndWVzdC5jYWxjX2xh" &
    "dW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFViwKICAgICAgICAg" &
    "ICAgICAgIDEsCiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgInRl" &
    "c3RzL2ZpeHR1cmVzL292bWZfQW1kU2V2X3N1ZmZpeC5iaW4iLAogICAgICAgICAgICAg" &
    "ICAgIi9kZXYvbnVsbCIsCiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAg" &
    "ICAgTm9uZSwKICAgICAgICAgICAgICAgIDB4MjEpCiAgICAgICAgc2VsZi5hc3NlcnRF" &
    "cXVhbCgKICAgICAgICAgICAgICAgIGxkLmhleCgpLAogICAgICAgICAgICAgICAgJzc3" &
    "ZjYxM2Q3YmJjZGYxMmE3Mzc4MmVhOWU4OGIwMTcyYWVkYTUwZDFhNTQyMDFjYjkwMzU5" &
    "NGZmNTI4NDY4OTgnKQoKICAgIGRlZiB0ZXN0X3Nldl93aXRoX292bWZ4NjRfYW5kX2tl" &
    "cm5lbF9zaG91bGRfZmFpbChzZWxmKToKICAgICAgICB3aXRoIHNlbGYuYXNzZXJ0UmFp" &
    "c2VzKFJ1bnRpbWVFcnJvcikgYXMgYzoKICAgICAgICAgICAgZ3Vlc3QuY2FsY19sYXVu" &
    "Y2hfZGlnZXN0KAogICAgICAgICAgICAgICAgICAgIFNldk1vZGUuU0VWLAogICAgICAg" &
    "ICAgICAgICAgICAgIDEsCiAgICAgICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAg" &
    "ICAgICAgICAgICAidGVzdHMvZml4dHVyZXMvb3ZtZl9Pdm1mWDY0X3N1ZmZpeC5iaW4i" &
    "LAogICAgICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAgICAgICAgICAgICAg" &
    "ICAgICIvZGV2L251bGwiLAogICAgICAgICAgICAgICAgICAgICIiLAogICAgICAgICAg" &
    "ICAgICAgICAgIDB4MjEpCiAgICAgICAgc2VsZi5hc3NlcnRFcXVhbChzdHIoYy5leGNl" &
    "cHRpb24pLAogICAgICAgICAgICAgICAgICAgICAgICAgIktlcm5lbCBzcGVjaWZpZWQg" &
    "YnV0IE9WTUYgZG9lc24ndCBzdXBwb3J0IGtlcm5lbC9pbml0cmQvY21kbGluZSBtZWFz" &
    "dXJlbWVudCIpCgogICAgZGVmIHRlc3Rfc25wX2R1bXBfdm1zYShzZWxmKToKICAgICAg" &
    "ICAiIiJUZXN0IHRoYXQgU0VWLVNOUCBtb2RlIGNyZWF0ZXMgdm1zYSBmaWxlcyBpZiBy" &
    "ZXF1cmVzdGVkLiIiIgogICAgICAgIGZpeHR1cmVzX2RpciA9IHBhdGhsaWIuUGF0aCgn" &
    "dGVzdHMvZml4dHVyZXMnKS5hYnNvbHV0ZSgpCiAgICAgICAgd2l0aCB0ZW1wZmlsZS5U" &
    "ZW1wb3JhcnlEaXJlY3RvcnkoKSBhcyB0bXA6CiAgICAgICAgICAgIHdpdGggcHVzaF9k" &
    "aXIodG1wKToKICAgICAgICAgICAgICAgIG92bWZfaGFzaCA9ICdjYWI3ZTA4NTg3NGIz" &
    "YWNmZGJlMmQ5NmRjYWEzMTI1MTExZjAwYzM1YzZmYzk3MDg0NjRjMmFlNzRiZmRiMDQ4" &
    "YTE5OGNiOWE5Y2NhZTBiM2U1ZTFhMzNmNWYyNDk4MTknCiAgICAgICAgICAgICAgICBn" &
    "dWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICAgICAgICAgIFNl" &
    "dk1vZGUuU0VWX1NOUCwKICAgICAgICAgICAgICAgICAgICAgICAgMSwKICAgICAgICAg" &
    "ICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVfU0lHU1siRVBZQy12NCJdLAogICAg" &
    "ICAgICAgICAgICAgICAgICAgICBmaXh0dXJlc19kaXIgLyAib3ZtZl9BbWRTZXZfc3Vm" &
    "Zml4LmJpbiIsCiAgICAgICAgICAgICAgICAgICAgICAgICIvZGV2L251bGwiLAogICAg" &
    "ICAgICAgICAgICAgICAgICAgICAiL2Rldi9udWxsIiwKICAgICAgICAgICAgICAgICAg" &
    "ICAgICAgIiIsCiAgICAgICAgICAgICAgICAgICAgICAgIDB4MjEsCiAgICAgICAgICAg" &
    "ICAgICAgICAgICAgIHNucF9vdm1mX2hhc2hfc3RyPW92bWZfaGFzaCwKICAgICAgICAg" &
    "ICAgICAgICAgICAgICAgZHVtcF92bXNhPVRydWUpCiAgICAgICAgICAgICAgICBzZWxm" &
    "LmFzc2VydFRydWUocGF0aGxpYi5QYXRoKCJ2bXNhMC5iaW4iKS5leGlzdHMoKSkKICAg" &
    "ICAgICAgICAgICAgIHNlbGYuYXNzZXJ0RmFsc2UocGF0aGxpYi5QYXRoKCJ2bXNhMS5i" &
    "aW4iKS5leGlzdHMoKSkKCiAgICBkZWYgdGVzdF9zZXZfd2l0aF9vdm1meDY0X3dpdGhv" &
    "dXRfa2VybmVsKHNlbGYpOgogICAgICAgIGxkID0gZ3Vlc3QuY2FsY19sYXVuY2hfZGln" &
    "ZXN0KAogICAgICAgICAgICAgICAgU2V2TW9kZS5TRVYsCiAgICAgICAgICAgICAgICAx" &
    "LAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAgICJ0ZXN0cy9maXh0" &
    "dXJlcy9vdm1mX092bWZYNjRfc3VmZml4LmJpbiIsCiAgICAgICAgICAgICAgICBOb25l" &
    "LAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAgIE5vbmUsCiAgICAg" &
    "ICAgICAgICAgICAweDIxKQogICAgICAgIHNlbGYuYXNzZXJ0RXF1YWwoCiAgICAgICAg" &
    "ICAgICAgICBsZC5oZXgoKSwKICAgICAgICAgICAgICAgICdiNGMwMjFlMDg1ZmI4M2Nl" &
    "ZmZlNjU3MWEzZDM1N2I0YTk4NzczYzgzYzQ3NGU0N2Y3NmM4NzY3MDhmZTMxNmRhJykK" &
    "CiAgICBkZWYgdGVzdF9zbnBfc3ZzbV80X3ZjcHVzKHNlbGYpOgogICAgICAgICIiIlRl" &
    "c3QgdGhhdCBTTlAtU1ZTTSBtb2RlIHByb2R1Y2VzIGNvcnJlY3QgbWVhc3VyZW1lbnQg" &
    "dmFsdWUgd2hlbiB1c2luZyA0IHZDUFVzIiIiCiAgICAgICAgbGQgPSBndWVzdC5jYWxj" &
    "X2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZNb2RlLlNFVl9TTlBfU1ZT" &
    "TSwKICAgICAgICAgICAgICAgIDQsCiAgICAgICAgICAgICAgICB2Y3B1X3R5cGVzLkNQ" &
    "VV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAgICAndGVzdHMvZml4dHVyZXMv" &
    "c3ZzbV9vdm1mLmZkJywKICAgICAgICAgICAgICAgIE5vbmUsCiAgICAgICAgICAgICAg" &
    "ICBOb25lLAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAgIDB4MjEs" &
    "CiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgdm1tX3R5cGVzLlZN" &
    "TVR5cGUuUUVNVSwKICAgICAgICAgICAgICAgIEZhbHNlLAogICAgICAgICAgICAgICAg" &
    "J3Rlc3RzL2ZpeHR1cmVzL3N2c20uYmluJywKICAgICAgICAgICAgICAgIDU0MDY3MikK" &
    "ICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAgICAgICAgbGQuaGV4KCks" &
    "CiAgICAgICAgICAgICAgICAnMjdkMTU0YzI3YjdiMzU5YzkzNWUyNTBlYzZmZWU3MmFh" &
    "MGFlOGMxMjI1ZTNiMGUxY2Y0NmE5NTY3ZTkzODA2NmQ3ZDZmOTRiYmRjNGE4NTc4MThi" &
    "ZGI3OTI3N2E0NGIyJykKCiAgICBkZWYgdGVzdF9zbnBfc3ZzbV8yX3ZjcHVzKHNlbGYp" &
    "OgogICAgICAgICIiIlRlc3QgdGhhdCBTTlAtU1ZTTSBtb2RlIHByb2R1Y2VzIGNvcnJl" &
    "Y3QgbWVhc3VyZW1lbnQgdmFsdWUgd2hlbiB1c2luZyAyIHZDUFVzIiIiCiAgICAgICAg" &
    "bGQgPSBndWVzdC5jYWxjX2xhdW5jaF9kaWdlc3QoCiAgICAgICAgICAgICAgICBTZXZN" &
    "b2RlLlNFVl9TTlBfU1ZTTSwKICAgICAgICAgICAgICAgIDIsCiAgICAgICAgICAgICAg" &
    "ICB2Y3B1X3R5cGVzLkNQVV9TSUdTWyJFUFlDLXY0Il0sCiAgICAgICAgICAgICAgICAn" &
    "dGVzdHMvZml4dHVyZXMvc3ZzbV9vdm1mLmZkJywKICAgICAgICAgICAgICAgIE5vbmUs" &
    "CiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAgICAgTm9uZSwKICAgICAg" &
    "ICAgICAgICAgIDB4MjEsCiAgICAgICAgICAgICAgICBOb25lLAogICAgICAgICAgICAg" &
    "ICAgdm1tX3R5cGVzLlZNTVR5cGUuUUVNVSwKICAgICAgICAgICAgICAgIEZhbHNlLAog" &
    "ICAgICAgICAgICAgICAgJ3Rlc3RzL2ZpeHR1cmVzL3N2c20uYmluJywKICAgICAgICAg" &
    "ICAgICAgIDU0MDY3MikKICAgICAgICBzZWxmLmFzc2VydEVxdWFsKAogICAgICAgICAg" &
    "ICAgICAgbGQuaGV4KCksCiAgICAgICAgICAgICAgICAnOWI5NDc0NTAzNmFhZmRkZjRm" &
    "N2Y4YjAwYzc1MTNhYmI1Yjc3MDMxNzhjYjk1YWFhNTc5MjhiZDk2M2Q2OGQzYmZjYjcx" &
    "NWQ2MDE5YjkxNjdlZTI1MTdiMTFiMGQ5YmU3JykKCiAgICBkZWYgdGVzdF9zbnBfc3Zz" &
    "bV9kdW1wX3Ztc2Eoc2VsZik6CiAgICAgICAgIiIiVGVzdCB0aGF0IFNOUC1TVlNNIG1v" &
    "ZGUgY3JlYXRlcyB2bXNhIGZpbGVzIGlmIHJlcXVyZXN0ZWQuIiIiCiAgICAgICAgZml4" &
    "dHVyZXNfZGlyID0gcGF0aGxpYi5QYXRoKCd0ZXN0cy9maXh0dXJlcycpLmFic29sdXRl" &
    "KCkKICAgICAgICB3aXRoIHRlbXBmaWxlLlRlbXBvcmFyeURpcmVjdG9yeSgpIGFzIHRt" &
    "cDoKICAgICAgICAgICAgd2l0aCBwdXNoX2Rpcih0bXApOgogICAgICAgICAgICAgICAg" &
    "Z3Vlc3QuY2FsY19sYXVuY2hfZGlnZXN0KAogICAgICAgICAgICAgICAgICAgICAgICBT" &
    "ZXZNb2RlLlNFVl9TTlBfU1ZTTSwKICAgICAgICAgICAgICAgICAgICAgICAgMiwKICAg" &
    "ICAgICAgICAgICAgICAgICAgICAgdmNwdV90eXBlcy5DUFVfU0lHU1siRVBZQy12NCJd" &
    "LAogICAgICAgICAgICAgICAgICAgICAgICBmaXh0dXJlc19kaXIgLyAnc3ZzbV9vdm1m" &
    "LmZkJywKICAgICAgICAgICAgICAgICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAg" &
    "ICAgICAgICAgTm9uZSwKICAgICAgICAgICAgICAgICAgICAgICAgTm9uZSwKICAgICAg" &
    "ICAgICAgICAgICAgICAgICAgMHgyMSwKICAgICAgICAgICAgICAgICAgICAgICAgTm9u" &
    "ZSwKICAgICAgICAgICAgICAgICAgICAgICAgdm1tX3R5cGVzLlZNTVR5cGUuUUVNVSwK" &
    "ICAgICAgICAgICAgICAgICAgICAgICAgVHJ1ZSwKICAgICAgICAgICAgICAgICAgICAg" &
    "ICAgZml4dHVyZXNfZGlyIC8gJ3N2c20uYmluJywKICAgICAgICAgICAgICAgICAgICAg" &
    "ICAgNTQwNjcyKQogICAgICAgICAgICAgICAgc2VsZi5hc3NlcnRUcnVlKHBhdGhsaWIu" &
    "UGF0aCgidm1zYTAuYmluIikuZXhpc3RzKCkpCiAgICAgICAgICAgICAgICBzZWxmLmFz" &
    "c2VydFRydWUocGF0aGxpYi5QYXRoKCJ2bXNhMS5iaW4iKS5leGlzdHMoKSkKICAgICAg" &
    "ICAgICAgICAgIHNlbGYuYXNzZXJ0RmFsc2UocGF0aGxpYi5QYXRoKCJ2bXNhMi5iaW4i" &
    "KS5leGlzdHMoKSkKCgpAY29udGV4dGxpYi5jb250ZXh0bWFuYWdlcgpkZWYgcHVzaF9k" &
    "aXIoZGlyOiBzdHIpOgogICAgIiIiQ29udGV4dCBtYW5hZ2VkIHN3aXRjaGluZyBvZiB0" &
    "aGUgd29ya2luZyBkaXJlY3RvcnkiIiIKICAgIHByZXZpb3VzID0gb3MuZ2V0Y3dkKCkK" &
    "ICAgIG9zLmNoZGlyKGRpcikKICAgIHRyeToKICAgICAgICB5aWVsZAogICAgZmluYWxs" &
    "eToKICAgICAgICBvcy5jaGRpcihwcmV2aW91cykK"

  UpstreamMeasureTestsSha256* =
    "801e0f89f2cd6a6f55a1f867e9ad42679336cc9bf1debc24e57d25ac2e3e68f4"

  UpstreamMeasureTestsBytes* = 18798

  UpstreamOvmfAmdSevSuffixHex* =
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffff2e06a01b79c782458566336ae8f78f09" &
    "afaa0108480b00f80c0000190000000000000000240b001931c02d001000003d0000" &
    "00ff72598178107ac07354751d817814cb3dca4d7514817818bd6f1e96750b81781c" &
    "89e7349a7502eb2481781078e58c8c75c58178143d8a1c4f75bc8178189935896175" &
    "b381781c85c32dd375aa8378240075a489c3035820759deb09b8bfbfbfbf89c5ebfe" &
    "89c5e9db09000031db89de89e8668b5d3001d8723beb0340723685c0743283c00772" &
    "2d24f88a5817f6c32074ea8b481481e1ffffff0009c974dd01c1740272d780781203" &
    "7506eb1785c0750689c8ebca31c089c685f6750274fee98809000085c0745f83c018" &
    "39c8735880780310741b8078031274328b1881e3ffffff0001d8724083c003723b24" &
    "fcebdb83c0046681384d5a752d0fb7583c01c3813b50450000751f034328eb1f83c0" &
    "0489c366813b565a750e03430883c0280fb75b0629d8eb05b800000000e97cffffff" &
    "90909090f3f9eae98e16d544a8eb7f4d8738f6ae54445646d0000000010000000600" &
    "00000040080000c037000040c8ff0000000000c03700000000000000000001000000" &
    "00000000004008000000c0ff00000000004008000000000001000000000000000000" &
    "000000000000002081000000000000e0000000000000030000000000000000000000" &
    "0000000000b080000000000000200000000000000300000000000000000000000000" &
    "00000090800000000000002000000000000002000000000000000000000000000000" &
    "000080000000000000600000000000000300000000000000e9890000000f20e00fba" &
    "e8050f22e031dbe96b03000085c07538b9800000c00f320fbae8080f3031dbb90100" &
    "00000fa30d04b08000731b0fc7f173fb890d0cb080000fc7f273fb891510b08000bb" &
    "010000000f20c00fbae81f0f22c0ea63f7ffff380085db7412390c250cb080007515" &
    "39142510b08000750c813df6ffffff813df6ff7404faf4ebfce9ae070000e9ca0200" &
    "0083f8010f845b01000083f8020f84f1010000e9f0030000803d00b08000010f849d" &
    "000000b90018000031c089048dfcff7f00e2f7c7050000800023108000c705040080" &
    "0000000000c7050010800023208000c7050410800000000000c70508108000233080" &
    "00c7050c10800000000000c7051010800023408000c7051410800000000000c70518" &
    "10800023508000c7051c10800000000000b90008000089c848c1e01505e300000089" &
    "04cdf81f8000c704cdfc1f800000000000e2e1e942010000b90018000031c089048d" &
    "fcff7f00e2f7e926030000c7050000800023108000c7050400800000000000c70500" &
    "10800023208000c7050410800000000000c7050810800023308000c7050c10800000" &
    "000000c7051010800023408000c7051410800000000000c7051810800023508000c7" &
    "051c10800000000000b90008000089c848c1e01505e30000008904cdf81f80008914" &
    "cdfc1f8000e2e5e93b020000e99f000000b90018000031c089048dfcff7f00e2f7c7" &
    "050000800023108000c7050400800000000000c7050010800023208000c705041080" &
    "0000000000c7050810800023308000c7050c10800000000000c70510108000234080" &
    "00c7051410800000000000c7051810800023508000c7051c10800000000000b90008" &
    "000089c848c1e01505e30000008904cdf81f8000c704cdfc1f800000000000e2e1e9" &
    "e1000000eb00b8000080000f22d8e962fdffffb8000000000fa281fb47656e757556" &
    "81fa696e6549754e81f96e74656c7546b8010000000fa2f7c1000000807437b80000" &
    "00000fa283f8217c2bb821000000b9000000000fa281fb496e7465751781fa6c5444" &
    "58750f81f9202020207507b801000000eb0231c0eb02eb9585c0742083fe00740b80" &
    "3d04b080000074f7eb10c60500b080000283e33f891d08b08000eb24fab8c8feffff" &
    "0f0110ea44faffff100066b818008ed88ec08ee08ee88ed0eb02ebdeebb4e9d00400" &
    "0031c0803d00b0800002750831d2a004b0800040e91efdffffc60504b0800001e913" &
    "ffffff31c0803d00b08000027505b801000000e980fcffff90909090909090909090" &
    "00000000000000000000000041534556640000000100000007000000000080000090" &
    "00000100000000a08000003000000100000000d08000001000000200000000e08000" &
    "001000000300000000f0800000100000040000000000810000100000100000000010" &
    "810000f0000001000000b802000000c1e0100d0011000031d2b9300101c00f30f30f" &
    "01d9f4ebfdb9010000000fa30d04b08000734fb904000000b8238080008904cd0020" &
    "8000c704cd0420800000000000b90002000089c848c1e00c050000800083c0638904" &
    "cdf87f80008914cdfc7f8000e2e2b909000000c704cd0480800000000000e963fdff" &
    "ff8b1518b08000e9cffcffffb919000000b804b08000c6000040e2fabc00008200b8" &
    "76fdffff2e0f0118b8000000800fa23d1f0000807c5eb81f0000800fa20fbae00173" &
    "51b9310101c00f320fbae0007344c60500b0800001a304b08000891508b08000b931" &
    "0101c00f320fbae001730083e33f89d883eb207904faf4ebfc31d20fabdac70514b0" &
    "800000000000891518b08000eb0f803d1cb08000007404faf4ebfc31c050b87cfdff" &
    "ff2e0f011858bc00000000e962fbffffb801000000c1e0100d0011000031d2b93001" &
    "01c00f30f30f01d9f4ebfdcf8b44241c8b1d00e08000b910e08000c7042400000000" &
    "c744240400000000c744240800000000c744240c0000000083fb000f84c000000039" &
    "0175068379040074064b83c130ebe78b41188904248b411c894424048b4120894424" &
    "088b41248944240ce990000000c6051cb08000015983f9720f856affffff83ec2089" &
    "44241cb9310101c00f320fbae0020f8270ffffff31c089442418b9300101c00f3289" &
    "442414895424108b44241883f8047d3ac1e01e8b54241c83c804b9300101c00f30f3" &
    "0f01d9b9300101c00f3289c181e1ff0f000083f9050f85cffdffffc1e81e89148466" &
    "ff442418ebbd8b4424148b542410b9300101c00f308b04248b5c24048b4c24088b54" &
    "240c83c4206683042402cf90ff0090fdffff00000000000090909090909090909090" &
    "9090909000001000008e000000001000008e000000001000008e000000001000008e" &
    "000000001000008e000000001000008e000000001000008e000000001000008e0000" &
    "00001000008e000000001000008e000000001000008e000000001000008e00000000" &
    "1000008e000000001000008e000000001000008e000000001000008e000000001000" &
    "008e000000001000008e000000001000008e000000001000008e000000001000008e" &
    "000000001000008e000000001000008e000000001000008e000000001000008e0000" &
    "00001000008e000000001000008e000000001000008e000000001000008e0000cdfc" &
    "1000008effff00001000008e000000001000008e0000fabb00f08edbbbc8fe2e660f" &
    "011766b8230000000f22c066eaaffeffff1000b8400600000f22e066b818008ed88e" &
    "c08ee08ee88ed0eb58903f00d0feffff909000000000000000000000000000000000" &
    "ffff0000009bcf00ffff00000093cf000000000000000000ffff0000009b8f00ffff" &
    "000000930000ffff0000009baf00bf4250eb056689c4eb02ebf9e971ffc60500b080" &
    "0000eb05e927fbffffe9aef5ffffe920f6ffffe9c4f7ffffb8ffffffff4821c64821" &
    "c54821c44889e0ffe6900000000000000000d0090000160035657ae44a989847865e" &
    "4685a7bf8ec2540500001600666588dc4a989847a75e5585a7bf67cc000c81000004" &
    "00001a001f3755723b3a044b927b1da6efa8d45400008100000c00001a0061b32e4c" &
    "9b7dc34c8081127c90d3d29404b080001600de71f7007e1acb4f890e68c77e2fb44e" &
    "8800de82b596b21ff745baeaa366c55a082d00000000000000000000000056544600" &
    "0f20c0a8017405e92cffffffe911ff90"

  UpstreamOvmfAmdSevSuffixSha256* =
    "8f765dfabc127fc0a938a0744a3103ec15864d7d794eb4c398aa976b6d6ab16c"

  UpstreamOvmfX64SuffixHex* =
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" &
    "2e06a01b79c782458566336ae8f78f09bfaa0108380b00f80c000019000000000000" &
    "0000140b001931c02d001000003d000000ff72598178107ac07354751d817814cb3d" &
    "ca4d7514817818bd6f1e96750b81781c89e7349a7502eb2481781078e58c8c75c581" &
    "78143d8a1c4f75bc8178189935896175b381781c85c32dd375aa8378240075a489c3" &
    "035820759deb09b8bfbfbfbf89c5ebfe89c5e9cb09000031db89de89e8668b5d3001" &
    "d8723beb0340723685c0743283c007722d24f88a5817f6c32074ea8b481481e1ffff" &
    "ff0009c974dd01c1740272d7807812037506eb1785c0750689c8ebca31c089c685f6" &
    "750274fee97809000085c0745f83c01839c8735880780310741b8078031274328b18" &
    "81e3ffffff0001d8724083c003723b24fcebdb83c0046681384d5a752d0fb7583c01" &
    "c3813b50450000751f034328eb1f83c00489c366813b565a750e03430883c0280fb7" &
    "5b0629d8eb05b800000000e97cffffff90909090f3f9eae98e16d544a8eb7f4d8738" &
    "f6ae54445646d000000001000000060000000040080000c037000040c8ff00000000" &
    "00c0370000000000000000000100000000000000004008000000c0ff000000000040" &
    "08000000000001000000000000000000000000000000001081000000000000f00000" &
    "000000000300000000000000000000000000000000b0800000000000002000000000" &
    "00000300000000000000000000000000000000908000000000000020000000000000" &
    "02000000000000000000000000000000000080000000000000600000000000000300" &
    "000000000000e9890000000f20e00fbae8050f22e031dbe96b03000085c07538b980" &
    "0000c00f320fbae8080f3031dbb9010000000fa30d04b08000731b0fc7f173fb890d" &
    "0cb080000fc7f273fb891510b08000bb010000000f20c00fbae81f0f22c0ea73f7ff" &
    "ff380085db7412390c250cb08000751539142510b08000750c813df6ffffff813df6" &
    "ff7404faf4ebfce99e070000e9ca02000083f8010f845b01000083f8020f84f10100" &
    "00e9e0030000803d00b08000010f849d000000b90018000031c089048dfcff7f00e2" &
    "f7c7050000800023108000c7050400800000000000c7050010800023208000c70504" &
    "10800000000000c7050810800023308000c7050c10800000000000c7051010800023" &
    "408000c7051410800000000000c7051810800023508000c7051c10800000000000b9" &
    "0008000089c848c1e01505e30000008904cdf81f8000c704cdfc1f800000000000e2" &
    "e1e942010000b90018000031c089048dfcff7f00e2f7e916030000c7050000800023" &
    "108000c7050400800000000000c7050010800023208000c7050410800000000000c7" &
    "050810800023308000c7050c10800000000000c7051010800023408000c705141080" &
    "0000000000c7051810800023508000c7051c10800000000000b90008000089c848c1" &
    "e01505e30000008904cdf81f80008914cdfc1f8000e2e5e92b020000e99f000000b9" &
    "0018000031c089048dfcff7f00e2f7c7050000800023108000c70504008000000000" &
    "00c7050010800023208000c7050410800000000000c7050810800023308000c7050c" &
    "10800000000000c7051010800023408000c7051410800000000000c7051810800023" &
    "508000c7051c10800000000000b90008000089c848c1e01505e30000008904cdf81f" &
    "8000c704cdfc1f800000000000e2e1e9e1000000eb00b8000080000f22d8e962fdff" &
    "ffb8000000000fa281fb47656e75755681fa696e6549754e81f96e74656c7546b801" &
    "0000000fa2f7c1000000807437b8000000000fa283f8217c2bb821000000b9000000" &
    "000fa281fb496e7465751781fa6c544458750f81f9202020207507b801000000eb02" &
    "31c0eb02eb9585c0742083fe00740b803d04b080000074f7eb10c60500b080000283" &
    "e33f891d08b08000eb24fab8c8feffff0f0110ea54faffff100066b818008ed88ec0" &
    "8ee08ee88ed0eb02ebdeebb4e9c004000031c0803d00b0800002750831d2a004b080" &
    "0040e91efdffffc60504b0800001e913ffffff31c0803d00b08000027505b8010000" &
    "00e980fcffff90909090909090909090000000000000000041534556580000000100" &
    "00000600000000008000009000000100000000a08000003000000100000000d08000" &
    "001000000200000000e08000001000000300000000f0800000100000040000000000" &
    "81000000010001000000b802000000c1e0100d0011000031d2b9300101c00f30f30f" &
    "01d9f4ebfdb9010000000fa30d04b08000734fb904000000b8238080008904cd0020" &
    "8000c704cd0420800000000000b90002000089c848c1e00c050000800083c0638904" &
    "cdf87f80008914cdfc7f8000e2e2b909000000c704cd0480800000000000e973fdff" &
    "ff8b1518b08000e9dffcffffb919000000b804b08000c6000040e2fabc00008200b8" &
    "76fdffff2e0f0118b8000000800fa23d1f0000807c5eb81f0000800fa20fbae00173" &
    "51b9310101c00f320fbae0007344c60500b0800001a304b08000891508b08000b931" &
    "0101c00f320fbae001730083e33f89d883eb207904faf4ebfc31d20fabdac70514b0" &
    "800000000000891518b08000eb0f803d1cb08000007404faf4ebfc31c050b87cfdff" &
    "ff2e0f011858bc00000000e972fbffffb801000000c1e0100d0011000031d2b93001" &
    "01c00f30f30f01d9f4ebfdcf8b44241c8b1d00e08000b910e08000c7042400000000" &
    "c744240400000000c744240800000000c744240c0000000083fb000f84c000000039" &
    "0175068379040074064b83c130ebe78b41188904248b411c894424048b4120894424" &
    "088b41248944240ce990000000c6051cb08000015983f9720f856affffff83ec2089" &
    "44241cb9310101c00f320fbae0020f8270ffffff31c089442418b9300101c00f3289" &
    "442414895424108b44241883f8047d3ac1e01e8b54241c83c804b9300101c00f30f3" &
    "0f01d9b9300101c00f3289c181e1ff0f000083f9050f85cffdffffc1e81e89148466" &
    "ff442418ebbd8b4424148b542410b9300101c00f308b04248b5c24048b4c24088b54" &
    "240c83c4206683042402cf90ff0090fdffff00000000000090909090909090909090" &
    "9090909000001000008e000000001000008e000000001000008e000000001000008e" &
    "000000001000008e000000001000008e000000001000008e000000001000008e0000" &
    "00001000008e000000001000008e000000001000008e000000001000008e00000000" &
    "1000008e000000001000008e000000001000008e000000001000008e000000001000" &
    "008e000000001000008e000000001000008e000000001000008e000000001000008e" &
    "000000001000008e000000001000008e000000001000008e000000001000008e0000" &
    "00001000008e000000001000008e000000001000008e000000001000008e0000cdfc" &
    "1000008effff00001000008e000000001000008e0000fabb00f08edbbbc8fe2e660f" &
    "011766b8230000000f22c066eaaffeffff1000b8400600000f22e066b818008ed88e" &
    "c08ee08ee88ed0eb58903f00d0feffff909000000000000000000000000000000000" &
    "ffff0000009bcf00ffff00000093cf000000000000000000ffff0000009b8f00ffff" &
    "000000930000ffff0000009baf00bf4250eb056689c4eb02ebf9e971ffc60500b080" &
    "0000eb05e937fbffffe9bef5ffffe930f6ffffe9d4f7ffffb8ffffffff4821c64821" &
    "c54821c44889e0ffe6900000000000000000c0090000160035657ae44a989847865e" &
    "4685a7bf8ec2480500001600666588dc4a989847a75e5585a7bf67cc000000000000" &
    "00001a001f3755723b3a044b927b1da6efa8d45400000000000000001a0061b32e4c" &
    "9b7dc34c8081127c90d3d29404b080001600de71f7007e1acb4f890e68c77e2fb44e" &
    "8800de82b596b21ff745baeaa366c55a082d00000000000000000000000056544600" &
    "0f20c0a8017405e92cffffffe911ff90"

  UpstreamOvmfX64SuffixSha256* =
    "b4c021e085fb83ceffe6571a3d357b4a98773c83c474e47f76c876708fe316da"

  UpstreamVcpuTypesBase64* =
    "ZGVmIGNwdV9zaWcoZmFtaWx5OiBpbnQsIG1vZGVsOiBpbnQsIHN0ZXBwaW5nOiBpbnQp" &
    "IC0+IGludDoKICAgICIiIkNvbXB1dGUgdGhlIDMyLWJpdCBDUFVJRCBzaWduYXR1cmUg" &
    "ZnJvbSBmYW1pbHksIG1vZGVsLCBhbmQgc3RlcHBpbmcuCgogICAgVGhpcyBjb21wdXRh" &
    "dGlvbiBpcyBkZXNjcmliZWQgaW4gQU1EJ3MgQ1BVSUQgU3BlY2lmaWNhdGlvbiwgcHVi" &
    "bGljYXRpb24gIzI1NDgxCiAgICBodHRwczovL3d3dy5hbWQuY29tL3N5c3RlbS9maWxl" &
    "cy9UZWNoRG9jcy8yNTQ4MS5wZGYKICAgIFNlZSBzZWN0aW9uOiBDUFVJRCBGbjAwMDBf" &
    "MDAwMV9FQVggRmFtaWx5LCBNb2RlbCwgU3RlcHBpbmcgSWRlbnRpZmllcnMKICAgICIi" &
    "IgogICAgaWYgZmFtaWx5ID4gMHhmOgogICAgICAgIGZhbWlseV9sb3cgPSAweGYKICAg" &
    "ICAgICBmYW1pbHlfaGlnaCA9IChmYW1pbHkgLSAweDBmKSAmIDB4ZmYKICAgIGVsc2U6" &
    "CiAgICAgICAgZmFtaWx5X2xvdyA9IGZhbWlseQogICAgICAgIGZhbWlseV9oaWdoID0g" &
    "MAoKICAgIG1vZGVsX2xvdyA9IG1vZGVsICYgMHhmCiAgICBtb2RlbF9oaWdoID0gKG1v" &
    "ZGVsID4+IDQpICYgMHhmCgogICAgc3RlcHBpbmdfbG93ID0gc3RlcHBpbmcgJiAweGYK" &
    "CiAgICByZXR1cm4gKChmYW1pbHlfaGlnaCA8PCAyMCkgfAogICAgICAgICAgICAobW9k" &
    "ZWxfaGlnaCA8PCAxNikgfAogICAgICAgICAgICAoZmFtaWx5X2xvdyA8PCA4KSB8CiAg" &
    "ICAgICAgICAgIChtb2RlbF9sb3cgPDwgNCkgfAogICAgICAgICAgICBzdGVwcGluZ19s" &
    "b3cpCgoKIyBMaXN0IHRoZSBDUFUgdHlwZXMgdGhhdCBhcHBlYXIgaW4gUUVNVSdzIGJ1" &
    "aWx0aW5feDg2X2RlZnMKQ1BVX1NJR1MgPSB7CiAgICAnRVBZQyc6IGNwdV9zaWcoZmFt" &
    "aWx5PTIzLCBtb2RlbD0xLCBzdGVwcGluZz0yKSwKICAgICdFUFlDLXYxJzogY3B1X3Np" &
    "ZyhmYW1pbHk9MjMsIG1vZGVsPTEsIHN0ZXBwaW5nPTIpLAogICAgJ0VQWUMtdjInOiBj" &
    "cHVfc2lnKGZhbWlseT0yMywgbW9kZWw9MSwgc3RlcHBpbmc9MiksCiAgICAnRVBZQy1J" &
    "QlBCJzogY3B1X3NpZyhmYW1pbHk9MjMsIG1vZGVsPTEsIHN0ZXBwaW5nPTIpLAogICAg" &
    "J0VQWUMtdjMnOiBjcHVfc2lnKGZhbWlseT0yMywgbW9kZWw9MSwgc3RlcHBpbmc9Miks" &
    "CiAgICAnRVBZQy12NCc6IGNwdV9zaWcoZmFtaWx5PTIzLCBtb2RlbD0xLCBzdGVwcGlu" &
    "Zz0yKSwKICAgICdFUFlDLVJvbWUnOiBjcHVfc2lnKGZhbWlseT0yMywgbW9kZWw9NDks" &
    "IHN0ZXBwaW5nPTApLAogICAgJ0VQWUMtUm9tZS12MSc6IGNwdV9zaWcoZmFtaWx5PTIz" &
    "LCBtb2RlbD00OSwgc3RlcHBpbmc9MCksCiAgICAnRVBZQy1Sb21lLXYyJzogY3B1X3Np" &
    "ZyhmYW1pbHk9MjMsIG1vZGVsPTQ5LCBzdGVwcGluZz0wKSwKICAgICdFUFlDLVJvbWUt" &
    "djMnOiBjcHVfc2lnKGZhbWlseT0yMywgbW9kZWw9NDksIHN0ZXBwaW5nPTApLAogICAg" &
    "J0VQWUMtTWlsYW4nOiBjcHVfc2lnKGZhbWlseT0yNSwgbW9kZWw9MSwgc3RlcHBpbmc9" &
    "MSksCiAgICAnRVBZQy1NaWxhbi12MSc6IGNwdV9zaWcoZmFtaWx5PTI1LCBtb2RlbD0x" &
    "LCBzdGVwcGluZz0xKSwKICAgICdFUFlDLU1pbGFuLXYyJzogY3B1X3NpZyhmYW1pbHk9" &
    "MjUsIG1vZGVsPTEsIHN0ZXBwaW5nPTEpLAogICAgJ0VQWUMtR2Vub2EnOiBjcHVfc2ln" &
    "KGZhbWlseT0yNSwgbW9kZWw9MTcsIHN0ZXBwaW5nPTApLAogICAgJ0VQWUMtR2Vub2Et" &
    "djEnOiBjcHVfc2lnKGZhbWlseT0yNSwgbW9kZWw9MTcsIHN0ZXBwaW5nPTApLAogICAg" &
    "J0VQWUMtVHVyaW4nOiBjcHVfc2lnKGZhbWlseT0yNiwgbW9kZWw9MCwgc3RlcHBpbmc9" &
    "MCksCn0K"

  UpstreamVcpuTypesSha256* =
    "c0bffd98b4ebcd02909bcdb4bea124ae7531bfc2e9bfd7a8babe4748ded7df76"

  UpstreamVcpuTypesBytes* = 1791

  # -------------------------------------------------------------------
  # A second class of vector, weaker than the corpus and kept apart
  #
  # Everything above is bytes UPSTREAM PUBLISHES. Everything below is a
  # value the reference implementation PRODUCES, at the pinned commit,
  # over an input this gate builds out of published bytes. It is a
  # weaker kind of evidence and it is segregated so that nobody reads it
  # as the other kind.
  #
  # It exists because the published corpus is degenerate in three
  # places, every one of them found by mutating this repository's own
  # gate rather than by reading it:
  #
  #   * every firmware fixture upstream ships is exactly ONE page, so
  #     the page walk's per-page address never varies and dropping it
  #     changed nothing;
  #   * every vector upstream states for one of the three hypervisors is
  #     SINGLE-processor, so that hypervisor's rule for processors after
  #     the first had no input at all;
  #   * every kernel and every initial ramdisk it names is the null
  #     device, so a build that read NEITHER file produced every
  #     published number correctly.
  #
  # Reproducing these needs no part of this repository:
  #
  #   git clone https://github.com/virtee/sev-snp-measure && cd sev-snp-measure
  #   git checkout 8f2b337e38bc83f87cd30f3253cdfe8e3e12cc3a
  #   python3 -c 'from sevsnpmeasure import guest, vcpu_types, vmm_types; ...'
  #
  # with the firmware images built as `ReferenceWalkInputs` describes.
  # -------------------------------------------------------------------

  ReferenceWalkInputs*: array[3, tuple[name, fill, digest: string]] = [
    ("one page of zeros, then the published firmware", "00",
     "788cbd3fb0e6a3011ed9d6a459539fcf1860b46f75f10f791b2941d0c88a58d9" &
     "404dfcbc64cc1a55e667949564dd4a45"),
    ("a page of zeros, a page of 0xaa, then the published firmware", "00aa",
     "dbed778c61f47d502eb247a42970650195979d1116026f03106ad4b8b63d2453" &
     "408a52ebeffaa6d34976dd96471bcd47"),
    ("the same two pages the other way round", "aa00",
     "87455a222ebc0c1e33b5f97379ab79799bdf9ba6ab65b10593a2a8e9c8d4b405" &
     "8751db328f26bf4a186712a3eb7cf269")]
    ## `fill` is the filler pages, one byte each, written IN ORDER in
    ## front of `UpstreamOvmfAmdSevSuffixHex`; `digest` is what
    ## `calc_snp_ovmf_hash` returns for the result. The third row is the
    ## second row's pages transposed, so it says the ORDER is inside the
    ## answer and not only the contents.

  ReferenceProcessorMatrix*: array[9, tuple[vmm: string; vcpus: int;
                                            digest: string]] = [
    ("qemu", 1,
     "e1e1ca029dd7973ab9513295be68198472dcd4fc834bd9af9b63f6e8a1674dbf" &
     "281a9278a4a2ebe0eed9f22adbcd0e2b"),
    ("qemu", 2,
     "7b4f6aa81aa1de12b78aeca2c639419006459bbadfdb707caf8710ebbf8c414a" &
     "d846acecf523c331c914e89ed06d9a6d"),
    ("qemu", 4,
     "d68d266388700e557d590470821a64a38014b2af64e3fe4e520f6806f41e876d" &
     "42215e43c25466708691b16c769d6f35"),
    ("ec2", 1,
     "ae6c3c4211ec24871cca94c9c627721a1be7e7386bcadf8293609e200d61f125" &
     "28a2e718b95b230ce063fb293d532dd0"),
    ("ec2", 2,
     "9d6c83ddf144c418a145c133f9ffbee7e2ff197feee73b0e57bc71955b0b6f09" &
     "b592c90b3094a27e72a1d84527fd4d07"),
    ("ec2", 4,
     "eb19df5094339442b2b9d773e09d7b77680d9fc2b5992fc8635af2c4ad2d363e" &
     "fc57d3337bba8ee50672df6aa0163b73"),
    ("gce", 1,
     "9c96dee4a68d83f9ddaec6d67894232d8ed6b419121c82f51453f955a24a767f" &
     "cc6c68dd54ed6d25bbf608877788a8fe"),
    ("gce", 2,
     "5b31e15bf3b3a041e4b0d9b675cca07981b27251e7115d8e67789bf0bddd3293" &
     "bb48a41c37d28edde9192d23bbbdea0d"),
    ("gce", 4,
     "25607ee3fbdd6cb2d697251c7eb1194ada8397819d8e80fdb1d33d4def6be1dd" &
     "27d86e75057595843c4be9f0fa8cbade")]
    ## The published firmware, no kernel, machine model `EPYC-v4`,
    ## feature word `0x21`, three hypervisors by three processor counts.
    ## The `("qemu", 1)` row is ALSO a published corpus row
    ## (`test_snp_without_kernel_default`), which is what says this
    ## matrix was produced by the same tool under the same reading as
    ## the corpus rather than by a different invocation of it.

  ReferenceKernelFixture* = "reprobuild launch-digest kernel fixture\n"
  ReferenceInitrdFixture* =
    "reprobuild launch-digest initial-ramdisk fixture\n"
  ReferenceCmdlineFixture* = "root=/dev/vda1 ro quiet"
  ReferenceOtherCmdline* = "root=/dev/vda2 ro quiet"
    ## Forty and forty-nine bytes of text, so that a build which read
    ## NEITHER file would produce the same number as one that read both.
    ## Every kernel and every initial ramdisk the published corpus names
    ## is the null device, which reads as nothing at all, so with the
    ## corpus alone a calculator that ignored both inputs was green.

  ReferenceKernelDigests*: array[4, tuple[name, kernel, initrd, cmdline,
                                          digest: string]] = [
    ("all three carry bytes", ReferenceKernelFixture,
     ReferenceInitrdFixture, ReferenceCmdlineFixture,
     "8794f2f1cd07a87e7211b23ccb94939405733191df99781fce9b8c8970739b3a" &
     "ebf2b5c2c38a1664ccbc767b0ddab7b4"),
    ("an empty initial ramdisk", ReferenceKernelFixture, "",
     ReferenceCmdlineFixture,
     "2a66b383c962b2e8935ec8895540d1fdb64644cec1cb4fabbba07577998d4086" &
     "3e52efc8b8d212c46a715fc4552de4f1"),
    ("an empty kernel", "", ReferenceInitrdFixture,
     ReferenceCmdlineFixture,
     "63a9f5d65e643efff54ec66c5193e5803bd8162b2d0f4f9e81b164acd99e58bb" &
     "0aa0fa2b7908d56d5445be3eb9c29450"),
    ("a different command line", ReferenceKernelFixture,
     ReferenceInitrdFixture, ReferenceOtherCmdline,
     "aeba6de6fffd60bccd9b965362f7cea335fd5a91581e661bf8fcf8add2d155d2" &
     "ae27132be9aec24bcedfdec2f16993c8")]
    ## One processor, the published firmware, machine model `EPYC-v4`,
    ## feature word `0x21`, a measured direct boot. The four rows differ
    ## from the first in one input each, so each of the three inputs is
    ## shown to reach the answer separately.

