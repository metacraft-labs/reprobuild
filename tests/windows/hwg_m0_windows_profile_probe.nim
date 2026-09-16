## HWG-M0 production PE/PDB identity and private-symbol probe.
##
## `allowed_mocks: none`. The caller supplies the real image and full PDB built
## with the production patchable-profile emitter. This process uses the same
## PE/PDB readers and serialized DbgHelp resolver as the Windows provider.

import std/[json, os]
import repro_hcr_linkgraph

proc require(condition: bool; message: string) =
  if not condition:
    raise newException(ValueError, message)

proc main() =
  require(paramCount() == 2, "usage: probe IMAGE PDB")
  let image = paramStr(1)
  let pdb = paramStr(2)
  let pe = parsePeCodeViewFacts(image)
  let identity = parsePdbIdentity(pdb)
  require(pe.identity == identity, "PE/PDB CodeView identity mismatch")
  let victim = resolveWindowsPdbFunction(image, pdb, "victim")
  let privateFunction = resolveWindowsPdbFunction(
    image, pdb, "second_private")
  require(victim.status == wprsOk and victim.matchCount == 1,
    "victim did not resolve exactly once: " & victim.reason)
  require(privateFunction.status == wprsOk and
      privateFunction.matchCount == 1,
    "second_private did not resolve exactly once: " & privateFunction.reason)
  require(victim.rva != 0 and privateFunction.rva != 0 and
      victim.rva != privateFunction.rva,
    "private function RVAs are empty or aliased")
  echo $(%*{
    "ok": true,
    "victimRva": victim.rva,
    "secondPrivateRva": privateFunction.rva,
    "privateFunctionCount": 2
  })

when isMainModule:
  main()
