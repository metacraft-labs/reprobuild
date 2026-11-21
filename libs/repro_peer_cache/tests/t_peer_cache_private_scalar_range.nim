## A private key read from a file is held to the range the generator
## samples from, [1, n-1] (ReproOS Add-On Mode spec §6.1: a kept recipient
## key must parse as the agent's recipient key; A14 re-review, item R1).
##
## Before this check `loadPrivateKeyFile` accepted a file of 32 zero bytes
## -- the point at infinity as a "public half", every ECDH secret derived
## against it public -- and the add-on preflight then kept it as a usable
## 0400 root key. The falsifier is the check's absence: with it removed,
## "a zero scalar is refused" and "a scalar at the group order is refused"
## go red (run and reverted before this file landed).
##
## No mocks: real key files under a temporary directory, the real loader.

import std/[os, strutils, unittest]

import repro_peer_cache/auth as peerAuth

const
  P256OrderHex = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"

let dir = getTempDir() / ("repro-peer-scalar-" & $getCurrentProcessId())
removeDir(dir)
createDir(dir)

proc keyFile(name, hex: string): string =
  result = dir / name
  writeFile(result, "ecdsa-p256:" & hex & "\n")

suite "a private scalar outside [1, n-1] is not a key":
  test "a zero scalar is refused":
    expect peerAuth.AuthError:
      discard peerAuth.loadPrivateKeyFile(keyFile("zero", repeat("00", 32)))

  test "a scalar at the group order is refused":
    expect peerAuth.AuthError:
      discard peerAuth.loadPrivateKeyFile(keyFile("order", P256OrderHex))

  test "a scalar above the group order is refused":
    expect peerAuth.AuthError:
      discard peerAuth.loadPrivateKeyFile(keyFile("above", repeat("ff", 32)))

  test "the scalar one below the order, and a generated key, load":
    let nMinusOne = P256OrderHex[0 ..< 62] & "50"
    discard peerAuth.loadPrivateKeyFile(keyFile("max", nMinusOne))
    let kp = peerAuth.generateKeypair()
    let p = dir / "generated"
    writeFile(p, peerAuth.privateKeyFileText(kp.privateKey))
    check peerAuth.derivePublicKey(peerAuth.loadPrivateKeyFile(p)) == kp.publicKey

  test "one is the smallest key":
    let one = peerAuth.loadPrivateKeyFile(keyFile("one", repeat("00", 31) & "01"))
    check one[31] == 1

removeDir(dir)
