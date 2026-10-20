## The deterministic fixture ecosystem, read back over the real read API
## and turned into visible states through the one shared adapter
## (`viewFor`) and derivation (`deriveStates`).
##
## Serves Protocol And Registry M4 (deterministic fixture datasets) and M8
## (a fixture ecosystem of originals, forks, compositions, incompatible
## releases, yanks, revocations, reviews, claims and blocked releases), and
## is the shared-API-data contract Product Experience M1 renders from.

import std/[os, tables, tempfiles, unittest]

import repro_remix
import repro_remix_registry

suite "Remix fixture ecosystem — every state from shared API data":

  test "each fixture shows exactly its expected states; identities are deterministic":
    let root = createTempDir("remix-fixtures-", "")
    let logKey = fixtureKey("registry-log")
    let policy = fixturePolicyKeys()
    var h = startDouble(root, logKey,
      policyKeys = @[Digest32(keyIdOf(policy[0])), Digest32(keyIdOf(policy[1]))],
      policyThreshold = 2)
    defer:
      h.stopDouble()
      removeDir(root)
    let eco = seedEcosystem(h, logKey)
    let fetch = httpFetch(h.readBase)
    var seen: seq[VisibleState]
    for name, id in eco.releases:
      let states = deriveStates(viewFor(fetch, id, eco.trust, eco.localPlatform))
      checkpoint name
      check states == eco.expected[name]
      for s in states:
        if s notin seen: seen.add s
    # The ecosystem covers every state a registry can produce; the three
    # purely client-side ones (stale policy, evidence unavailable,
    # incomplete lineage) and `unverifiable` come from the client's own
    # situation and are covered by the state-coverage check.
    for s in VisibleState:
      if s notin {vsStalePolicy, vsEvidenceUnavailable, vsIncompleteLineage,
                  vsUnverifiable}:
        checkpoint $s
        check s in seen
    check eco.releases.len == 10
    # Determinism: a second, independent double seeded the same way holds
    # the very same release identities.
    let root2 = createTempDir("remix-fixtures-", "")
    var h2 = startDouble(root2, logKey,
      policyKeys = @[Digest32(keyIdOf(policy[0])), Digest32(keyIdOf(policy[1]))],
      policyThreshold = 2)
    defer:
      h2.stopDouble()
      removeDir(root2)
    let eco2 = seedEcosystem(h2, logKey)
    for name, id in eco.releases:
      checkpoint name
      check eco2.releases[name] == id
