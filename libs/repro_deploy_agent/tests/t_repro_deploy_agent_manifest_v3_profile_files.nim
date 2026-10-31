## RDMF v3: a manifest carries the profile's compile-time files beside it.
##
## Governing spec: ``reprobuild-pm/spec/Deploy-Agent.md`` §"The `RDMF`
## envelope" (layout, versioning policy, strictness) and §"Field semantics",
## `profileFiles`. A deploy manifest used to carry the profile as ONE text,
## so a profile could not `staticRead` a sibling file (an apt closure lock)
## on the target and producers inlined every such file into the Nim source.
##
## Covered here, with the real codec, real ECDSA-P256 keys and a real
## staging directory (nothing mocked):
##   * a manifest with a bundle encodes as v3, signs, verifies, and decodes
##     to the same files, bytes and paths;
##   * the lowest-version rule: no bundle leaves v1 / v2 untouched;
##   * strictness: an absolute, `..`, backslash, empty or duplicate path is
##     refused by the encoder AND by the decoder, before the signature;
##   * staging writes each file at its relative path beside the module and
##     removes what a previous manifest left there.
##   * the lowest-version rule on the reading side: a v3 envelope with no
##     files and a v2 envelope without a sealed section are refused as
##     non-canonical, by name, before the signature is consulted;
##   * the reserved staged-profile name and file/directory prefix conflicts
##     are refused.
## The on-target compile that `staticRead`s a staged file, and a changed
## lock behind an unchanged profile text, are driven through the real binary
## in `t_deploy_agent_cli_compiles_manifest_profile` ("a bundled file the
## profile staticReads reaches the apply, and a changed one is recompiled").

import std/[os, strutils, unittest]

import repro_deploy_agent
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bundled(files: seq[ProfileFile]): DeployManifest =
  DeployManifest(target: "rpi2", sequence: 7'u64, deploymentId: "d-7",
    profileText: "import repro_profile\nconst lock = staticRead(\"locks/a.lock\")\n",
    profileFiles: files)

suite "RDMF v3: profile bundle":
  test "a bundle makes the envelope v3 and round-trips byte for byte":
    let files = @[
      ProfileFile(path: "locks/a.lock",
        content: "repro-apt-closure-lock v1\nroot a\n"),
      ProfileFile(path: "conf/blackbox.yml",
        content: "modules:\n  http_2xx: {prober: \"http\"}\n# c\n"),
      ProfileFile(path: "empty", content: "")]
    var m = bundled(files)
    check m.wireVersion == DeployManifestFormatVersionV3
    let kp = peerAuth.generateKeypair()
    signManifest(kp, m)
    check m.formatVersion == 3'u16
    let bytes = encodeManifest(m)
    let back = decodeManifest(bytes)
    check back.formatVersion == 3'u16
    check back.profileFiles == files
    check back.profileText == m.profileText
    check back.target == "rpi2" and back.sequence == 7'u64
    check verifyTrusted(back, anchorsFromKeypairs([kp.publicKey]))
    # The bundle is inside the signed prefix: changing one byte of a
    # bundled file breaks the signature.
    var tampered = back
    tampered.profileFiles[0].content[^2] = 'b'
    check not verifySignature(tampered)

  test "lowest-version rule: no bundle leaves v1 and v2 as they were":
    var m = bundled(@[])
    check m.wireVersion == DeployManifestFormatVersionV1
    let kp = peerAuth.generateKeypair()
    signManifest(kp, m)
    let back = decodeManifest(encodeManifest(m))
    check back.formatVersion == 1'u16
    check back.profileFiles.len == 0

  test "encoder and decoder refuse a path that could escape the staging dir":
    for bad in ["/etc/passwd", "../x", "a/../b", "a//b", "", "./a", "a\\b",
                "a/./b", "trailing/"]:
      var m = bundled(@[ProfileFile(path: bad, content: "x")])
      checkpoint "path: " & bad
      expect DeployManifestCodecError:
        discard encodeManifest(m)
    # Duplicates too.
    expect DeployManifestCodecError:
      discard encodeManifest(bundled(@[
        ProfileFile(path: "a", content: "1"), ProfileFile(path: "a", content: "2")]))
    # The decoder enforces it independently of the encoder: build a v3
    # envelope by hand around a bad path and check it is refused before the
    # signature is consulted (the signature here is garbage on purpose).
    var good = bundled(@[ProfileFile(path: "ok", content: "x")])
    let kp = peerAuth.generateKeypair()
    signManifest(kp, good)
    var bytes = encodeManifest(good)
    var s = newString(bytes.len)
    for i, b in bytes: s[i] = char(b)
    let at = s.find("ok")
    check at > 0
    s[at] = '.'; s[at + 1] = '.'
    var forged = newSeq[byte](s.len)
    for i, c in s: forged[i] = byte(c)
    expect DeployManifestCodecError:
      discard decodeManifest(forged)

  test "staging writes the bundle beside the module and drops stale files":
    let dir = getTempDir() / "t_rdmf_v3_stage_" & $getCurrentProcessId()
    defer: removeDir(dir)
    createDir(dir / "locks")
    writeFile(dir / "locks" / "stale.lock", "from a previous manifest")
    let module = stageProfileSources(dir, "const x = 1\n", [
      ProfileFile(path: "locks/a.lock", content: "A"),
      ProfileFile(path: "deep/er/f.txt", content: "F")])
    check module == dir / StagedProfileModule
    check readFile(module) == "const x = 1\n"
    check readFile(dir / "locks" / "a.lock") == "A"
    check readFile(dir / "deep" / "er" / "f.txt") == "F"
    check not fileExists(dir / "locks" / "stale.lock")
    # The staging check is its own guard, not a courtesy of the decoder.
    expect DeployManifestCodecError:
      discard stageProfileSources(dir, "", [
        ProfileFile(path: "../escape", content: "x")])

  test "reserved name and file/directory prefix conflicts are refused":
    for files in [
        @[ProfileFile(path: StagedProfileModule, content: "x")],
        @[ProfileFile(path: "a", content: "1"),
          ProfileFile(path: "a/b", content: "2")],
        @[ProfileFile(path: "a/b", content: "2"),
          ProfileFile(path: "a", content: "1")]]:
      expect DeployManifestCodecError:
        validateProfileFiles(files)
      expect DeployManifestCodecError:
        discard encodeManifest(bundled(files))
    # A shared directory is not a conflict.
    validateProfileFiles([ProfileFile(path: "a/b", content: "1"),
                          ProfileFile(path: "a/c", content: "2")])

  test "non-canonical envelopes are refused by name, before the signature":
    # A v3 envelope with zero files: forge the version byte of a v1
    # envelope and splice a zero file count after `profileText`.
    var m = bundled(@[])
    let kp = peerAuth.generateKeypair()
    signManifest(kp, m)
    let v1 = encodeManifest(m)
    # Layout: magic(4) version(2) reserved(2) target(len+n) seq(8)
    # deploymentId(len+n) profileText(len+n) | [v3: fileCount(4)] actions...
    var forged = v1[0 ..< 4] & @[3'u8, 0'u8] & v1[6 .. ^1]
    var pos = 8
    for _ in 0 ..< 3:   # target, (skip seq), deploymentId, profileText
      let n = int(forged[pos]) or (int(forged[pos + 1]) shl 8) or
        (int(forged[pos + 2]) shl 16) or (int(forged[pos + 3]) shl 24)
      pos += 4 + n
      if pos == 8 + 4 + m.target.len: pos += 8   # the u64 sequence
    forged = forged[0 ..< pos] & @[0'u8, 0'u8, 0'u8, 0'u8] & forged[pos .. ^1]
    try:
      discard decodeManifest(forged)
      check false
    except DeployManifestCodecError as e:
      check "non-canonical" in e.msg
    # A v2 envelope whose secrets flag is 0.
    var v2 = v1[0 ..< 4] & @[2'u8, 0'u8] & v1[6 .. ^1]
    # The flag sits right before the 65-byte producer key + 64-byte signature.
    let flagAt = v2.len - 64 - 65
    v2 = v2[0 ..< flagAt] & @[0'u8] & v2[flagAt .. ^1]
    try:
      discard decodeManifest(v2)
      check false
    except DeployManifestCodecError as e:
      check "non-canonical" in e.msg
