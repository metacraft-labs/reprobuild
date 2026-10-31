## Every key list and configuration file the deploy agent, its producer and
## the add-on read accepts non-ASCII UTF-8 in its comments, and never
## crashes on it or drops an entry because of it; the key material itself
## stays strictly validated (a key line with a non-ASCII byte is refused,
## by name, never half-read).
##
## The incident behind it (2026-10-31, 14:50Z): infra's Python producer
## opened the committed revoked-recipient-keys file as ASCII, and a comment
## citing "§10.3" (UTF-8 C2 A7) stopped every target's render on
## high-mem-server. This file pins the Nim side of the same files:
## ``loadTrustAnchors`` (the deploy-signer and cache-publisher anchors),
## ``loadAllowedSigners``, ``loadRevokedRecipientKeys`` and the host's list,
## ``caches.conf`` (``parseCachesText``) and ``agent.conf``
## (``parseAgentConf``).
##
## *Mocking.* None: real files, the real parsers.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_peer_cache/auth as peerAuth
import repro_deploy_agent/agent
import repro_deploy_agent/secrets
import repro_binary_cache_client/caches_config
import repro_addon/agent_split

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add(toHex(int(x), 2).toLowerAscii())

const
  Section = "# the add-on's revoked recipient keys (ReproOS Add-On Mode §10.3, CRED-2)"
    ## The exact comment line of infra's committed list.
  More = "# naïve café — “quoted” ✓"

let keyA = peerAuth.generateKeypair().publicKey
let keyB = peerAuth.generateKeypair().publicKey

proc listText(): string =
  "\xEF\xBB\xBF# a byte-order mark, then a comment\n" & Section & "\r\n" &
    More & "\n\n" & hexOf(keyA) & "\n  # indented " & More & "\n" &
    hexOf(keyB) & "\r\n"

suite "UTF-8 in comments":
  let tmp = createTempDir("utf8-lists-", "")
  let list = tmp / "keys.txt"
  writeFile(list, listText())

  test "trust anchors and allowed signers read every key":
    for anchors in [peerAuth.loadTrustAnchors(list), loadAllowedSigners(list)]:
      check anchors.publicKeys.len == 2
      check keyA in anchors.publicKeys and keyB in anchors.publicKeys

  test "the revoked recipient-key list reads every key":
    let r = loadRevokedRecipientKeys(list)
    check r.isRevoked(keyA) and r.isRevoked(keyB)
    check not r.isRevoked(peerAuth.generateKeypair().publicKey)

  test "a non-ASCII byte on a KEY line is refused by name":
    let bad = tmp / "bad.txt"
    # A no-break space after the key: not whitespace to a key parser.
    writeFile(bad, Section & "\n" & hexOf(keyA) & "\xC2\xA0\n")
    expect peerAuth.AuthError:
      discard peerAuth.loadTrustAnchors(bad)
    try:
      discard peerAuth.loadTrustAnchors(bad)
    except peerAuth.AuthError as e:
      check "line 2" in e.msg
    expect SecretsError:
      discard loadRevokedRecipientKeys(bad)

  test "caches.conf keeps its cache and keys":
    let text = "\xEF\xBB\xBF" & Section & "\n; " & More & "\n[addon]\n# " & More &
      "\nurl = \"https://cache.example\"\ntrusted-public-keys = \"" &
      hexOf(keyA) & "\"\n"
    let entries = parseCachesText(text, "caches.conf")
    check entries.len == 1
    check entries[0].url == "https://cache.example"
    check entries[0].trustedKeys.len == 1

  test "agent.conf keeps its target and sources":
    let c = parseAgentConf("\xEF\xBB\xBF" & Section & "\n" & More & "\ntarget = rpi2\n" &
      "source = http://192.0.2.1/m\n# " & More & "\nsource = http://192.0.2.2/m\n")
    check c.target == "rpi2"
    check c.sources.len == 2

  removeDir(tmp)
