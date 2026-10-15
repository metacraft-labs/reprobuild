## Shared-Development-Services L8 (§7) — THE MINTED IDENTIFIER REACHES A
## CONSUMING SERVICE'S ARGV, and the thing it replaces is named.
##
## §7's own account of the wrapper this lane exists to remove:
##
##   "The hand-written `run-api` wrapper in `isonim-platform`'s local
##    stack — which sources a file at process start because 'the OIDC
##    variables do not exist until `idp-bootstrap` has registered the
##    application with a running issuer' — is evidence of
##    **process-compose** rendering its manifest up front with no
##    resource lane, not of an inherent property of the value. Under
##    this model that wrapper is what gets deleted."
##
## What this file measures is the lane that makes the wrapper
## unnecessary: a token in a service's `command` is concretized when the
## supervisor builds its spec, which happens AFTER `repro up` has
## converged the shared instance and reconciled its registrations.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Every case calls the real `substituteMintedAttributes` and the real
## `writeSharedInstanceMinted` / `readSharedInstanceMinted` over a real
## directory on the real filesystem, with metadata of the shape a real
## `servicePlaceholder` emits.
##
## THE PROBE SET IS A CONSTANT: `UnresolvableProbes` below, asserted by
## a case of its own, for the reason L7's review recorded — three prose
## numbers for one set is how a probe set silently shrinks.

import std/[json, os, strutils, tables, unittest]

import repro_cli_support/dev_session

const
  UnresolvableProbes* = [
    ## Spellings that must NOT resolve, each for its own reason.
    "@minted:not-registered@",      ## an unknown member
    "@minted:@",                    ## an empty member name
    "@minted:isonim-site",          ## missing the closing marker
    "minted:isonim-site@"]          ## missing the prefix marker

proc scratchOut(tag: string): string =
  let root = getTempDir() / ("l8-argv-" & tag & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  root

suite "L8: a minted identifier is substituted into argv":

  test "a whole-argument token becomes the minted identifier":
    var minted = initTable[string, string]()
    minted["isonim-site"] = "client-abc123"
    let got = substituteMintedAttributes("api-server",
      @["--issuer", "https://login.metacraft-labs.test",
        "--client-id", "@minted:isonim-site@"], minted)
    check got == @["--issuer", "https://login.metacraft-labs.test",
                   "--client-id", "client-abc123"]

  test "a service-qualified key wins over the bare one":
    var minted = initTable[string, string]()
    minted["isonim-site"] = "bare"
    minted["api-server:isonim-site"] = "qualified"
    check substituteMintedAttributes("api-server",
      @["@minted:isonim-site@"], minted) == @["qualified"]

  test "a command with no token is returned unchanged":
    var minted = initTable[string, string]()
    minted["isonim-site"] = "client-abc123"
    let command = @["api-server", "8080"]
    check substituteMintedAttributes("api-server", command, minted) ==
      command

suite "L8: an unresolved token is REFUSED, never emptied or left verbatim":

  test "the probe set's size is read from the set":
    check UnresolvableProbes.len == 4

  test "an unknown member is refused, naming it and what IS registered":
    var minted = initTable[string, string]()
    minted["isonim-site"] = "client-abc123"
    var raised = false
    try:
      discard substituteMintedAttributes("api-server",
        @["@minted:codetracer-ide@"], minted)
    except ValueError as e:
      raised = true
      check "codetracer-ide" in e.msg
      check "isonim-site" in e.msg        ## what IS registered
      check "D-SS10" in e.msg
    check raised

  test "a token embedded in a larger argument is refused, not rewritten":
    var minted = initTable[string, string]()
    minted["isonim-site"] = "client-abc123"
    var raised = false
    try:
      discard substituteMintedAttributes("api-server",
        @["--client-id=@minted:isonim-site@"], minted)
    except ValueError as e:
      raised = true
      check "inside a larger" in e.msg
    check raised

  test "every unresolvable probe either refuses or passes through UNCHANGED":
    # The two acceptable answers, and "resolved to something" is not one
    # of them. A probe missing a marker is NOT a minted token, so it
    # must survive verbatim rather than be guessed at.
    var minted = initTable[string, string]()
    minted["isonim-site"] = "client-abc123"
    for probe in UnresolvableProbes:
      var refusedWith = ""
      var passedThrough: seq[string] = @[]
      try:
        passedThrough = substituteMintedAttributes("api-server",
          @[probe], minted)
      except ValueError as e:
        refusedWith = e.msg
      if refusedWith.len == 0:
        checkpoint("probe `" & probe & "` was neither refused nor " &
          "passed through unchanged: " & $passedThrough)
        check passedThrough == @[probe]
      else:
        check refusedWith.len > 0

suite "L8: the minted record crosses from `repro up` to the supervisor":

  test "it round-trips through the on-disk record":
    let outDir = scratchOut("roundtrip")
    writeSharedInstanceMinted(outDir, @[
      (serviceName: "sso", member: "isonim-site",
       mintedId: "client-abc123"),
      (serviceName: "sso", member: "codetracer-ide",
       mintedId: "client-def456")])
    let table = readSharedInstanceMinted(outDir)
    check table["isonim-site"] == "client-abc123"
    check table["sso:isonim-site"] == "client-abc123"
    check table["codetracer-ide"] == "client-def456"

  test "a missing record is the ordinary case and yields an empty table":
    check readSharedInstanceMinted(scratchOut("missing")).len == 0

  test "a record with a foreign schemaId is refused by name":
    let outDir = scratchOut("schema")
    createDir(outDir.sessionDir)
    writeFile(outDir.sharedInstanceMintedPath,
      """{"schemaId":"something.else.v1","registrations":[]}""")
    var raised = false
    try:
      discard readSharedInstanceMinted(outDir)
    except ValueError as e:
      raised = true
      check "something.else.v1" in e.msg
    check raised

  test "one member minted differently by two services loses its BARE key":
    # Ambiguity must not resolve to whichever row came last: the bare
    # key is dropped so the substitution refuses and the author sees the
    # qualified spelling in the message.
    let outDir = scratchOut("ambiguous")
    writeSharedInstanceMinted(outDir, @[
      (serviceName: "ssoOne", member: "shared-name", mintedId: "one"),
      (serviceName: "ssoTwo", member: "shared-name", mintedId: "two")])
    let table = readSharedInstanceMinted(outDir)
    check not table.hasKey("shared-name")
    check table["ssoOne:shared-name"] == "one"
    check table["ssoTwo:shared-name"] == "two"
