## A compiled system profile keeps its secrets: the `secrets.secretFile`
## declarations and each unit's `credentials` travel DSL -> adapter ->
## canonical text -> parser unchanged (ReproOS Add-On Mode §8.3, §10.3).
##
## The canonical text is what a compiled profile becomes on every path:
## `repro infra apply --profile system.nim`, and the deploy agent's
## `compile-profile`, whose output a producer signs. Before this, the text
## renderer wrote neither the declarations nor the `credentials` field, so
## a unit from a compiled profile lost its `LoadCredential=` lines and the
## apply materialised no secret; only hand-written text profiles had them.
##
## Falsifying check: the assertions on the rendered text fail against the
## renderer without the two emitters (the state before this test).
##
## *Mocking.* None: the production constructors, adapter and parser.

import std/[strutils, unittest]

import repro_infra
import repro_profile
import repro_profile_compile

const Unit = "[Service]\nExecStart=/usr/bin/true\n"

proc compiled(): SystemProfile =
  var intent = ProfileIntent(name: "secrets")
  secretFile(intent.resources, service = "vaultwarden", name = "admin-token")
  secretFile(intent.resources, service = "eth-beacon", name = "jwt")
  systemdSystemUnit(intent.resources, name = "vaultwarden.service",
    content = Unit, credentials = @["admin-token"])
  systemdSystemUnit(intent.resources, name = "eth-beacon.service",
    content = Unit, credentials = @["jwt"], exclusive = true)
  systemdSystemUnit(intent.resources, name = "plain.service", content = Unit)
  profileIntentToSystemProfile(intent)

proc unitNamed(sp: SystemProfile; name: string): SystemResource =
  for r in sp.resources:
    if r.kind == srkSystemdSystemUnit and r.suName == name:
      return r
  raise newException(KeyError, name)

suite "compiled profiles keep secrets and credentials":
  test "declarations and credentials survive the canonical text":
    let sp = compiled()
    check sp.secretFiles.len == 2
    let text = renderSystemProfileToText(sp)
    check text.count(SecretFileStanzaTag & " {") == 2
    check "credentials = [\"admin-token\"]" in text
    check "credentials = [\"jwt\"]" in text
    let back = parseSystemProfile(text)
    check back.secretFiles == sp.secretFiles
    check back.unitNamed("vaultwarden.service").suCredentials == @["admin-token"]
    check back.unitNamed("eth-beacon.service").suCredentials == @["jwt"]
    check back.unitNamed("eth-beacon.service").suExclusive
    check back.unitNamed("plain.service").suCredentials.len == 0
    # The rendered unit carries the credential lines on both sides.
    check renderedSystemUnitContent(back.unitNamed("vaultwarden.service")) ==
      renderedSystemUnitContent(sp.unitNamed("vaultwarden.service"))
    check "LoadCredential=admin-token:/run/repro/secrets/vaultwarden/admin-token" in
      renderedSystemUnitContent(back.unitNamed("vaultwarden.service"))
    # A second render of the parsed text is the same text.
    check renderSystemProfileToText(back) == text
