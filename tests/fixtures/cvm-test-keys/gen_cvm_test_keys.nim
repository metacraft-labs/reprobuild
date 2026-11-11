## Generates the RSA-4096 keys of the software-root security-processor
## test hierarchies (`tests/integration/cvm_evidence_emulator.nim`):
## the root and signing-authority keys of the MARKED hierarchy and of the
## UNMARKED one. Run by edge `reprobuild.test_fixtures.cvm_test_rsa_keys`
## (`repro.nim`), which declares the four files as its outputs.
##
## Each key comes from a FIXED seed, the SHA-256 of its name, so the edge
## is reproducible and the engine can cache it: the same generator source
## gives the same keys. Generating them costs about 15 CPU-seconds a key,
## which every test process paid at start-up before this edge existed.
##
## A fixed key weakens nothing these tests claim: the refusals they show
## are structural (the marker extension, and a root that is not a vendor
## root), not a property of the key being secret.
##
## Usage: gen_cvm_test_keys <output dir>

import std/[os, strutils]
import nimcrypto/sha2

import ../../integration/software_root_test_pki

const KeyNames* = ["snp-marked-ark", "snp-marked-ask",
                   "snp-unmarked-ark", "snp-unmarked-ask"]

proc seedOf(name: string): array[32, byte] =
  sha256.digest("reprobuild software-root test key: " & name).data

when isMainModule:
  if paramCount() != 1:
    quit("usage: gen_cvm_test_keys <output dir>", 2)
  let outDir = paramStr(1)
  createDir(outDir)
  for name in KeyNames:
    let key = newTestRsa4096KeyFromSeed(seedOf(name))
    let path = outDir / (name & ".key")
    writeFile(path & ".tmp", encodeTestRsaKey(key))
    moveFile(path & ".tmp", path)
    stdout.writeLine("wrote " & path)
