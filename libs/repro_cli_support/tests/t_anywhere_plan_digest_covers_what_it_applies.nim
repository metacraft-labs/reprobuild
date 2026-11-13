## `repro anywhere --mode addon`'s plan digest covers everything one
## acknowledged run applies (ReproOS Add-On Mode §6.5.3 step 4, amended and
## approved by Zahary Karadjov on 2026-11-13): the host's bootstrap plan,
## the bootstrap options, the add-on binary, the anchors' bytes and the
## canonical text of the profile applied after bootstrap. A change to any
## of them after the review is a different digest, which the acknowledged
## run refuses before it writes anything.
##
## No mocks: the real `anywherePlanDocument` / `anywherePlanDigest` /
## `renderAnywherePlan` / `sshOptions` on real anchor files. The SSH half is
## the e2e gate's (`e2e_addon_anywhere_remote_bootstrap_converges_clean_guest`).
##
## Falsifier: built with
## `-d:reproAddonMutation=anywhere-digest-omits-profile`, the profile case
## fails.

import std/[os, strutils, tempfiles, unittest]

import repro_cli_support/anywhere

suite "the anywhere plan digest covers what the run applies":
  let dir = createTempDir("repro-anywhere-digest-", "")
  writeFile(dir / "signers", "aa\n")
  writeFile(dir / "publishers", "bb\n")
  let base = AnywhereOptions(host: "tb", target: "root@127.0.0.1",
    addonSha256: "11", profileText: "fs.systemFile { path = \"/etc/a\" }\n",
    deploySigners: dir / "signers", cachePublishers: dir / "publishers",
    cacheUrl: "http://cache.example:7880")
  let d0 = anywherePlanDigest(anywherePlanDocument(base, "b0"))

  test "the same inputs give the same digest":
    check anywherePlanDigest(anywherePlanDocument(base, "b0")) == d0
    check d0.len == 64

  test "a profile changed after the review is another digest":
    var o = base
    o.profileText = base.profileText & "fs.systemFile { path = \"/etc/injected\" }\n"
    check anywherePlanDigest(anywherePlanDocument(o, "b0")) != d0

  test "the host's bootstrap plan, the binary and the options are covered":
    check anywherePlanDigest(anywherePlanDocument(base, "b1")) != d0
    var o = base
    o.addonSha256 = "12"
    check anywherePlanDigest(anywherePlanDocument(o, "b0")) != d0
    o = base
    o.cacheUrl = "http://other.example:7880"
    check anywherePlanDigest(anywherePlanDocument(o, "b0")) != d0
    o = base
    o.target = "root@127.0.0.2"
    check anywherePlanDigest(anywherePlanDocument(o, "b0")) != d0

  test "the anchors' bytes are covered, not only their names":
    writeFile(dir / "signers", "aa\ncc\n")
    check anywherePlanDigest(anywherePlanDocument(base, "b0")) != d0
    writeFile(dir / "signers", "aa\n")
    check anywherePlanDigest(anywherePlanDocument(base, "b0")) == d0

  test "the printed plan carries the profile text and the digest":
    let doc = anywherePlanDocument(base, "b0")
    let text = renderAnywherePlan(base, "plan digest: b0\n", doc, d0)
    check base.profileText.strip() in text
    check ("anywhere plan digest: " & d0) in text
    check doc in text

  test "ssh reads no ssh_config and trusts only --known-hosts":
    var o = base
    o.knownHosts = dir / "known_hosts"
    let opts = sshOptions(o)
    check opts[0 .. 1] == @["-F", "/dev/null"]
    check "StrictHostKeyChecking=yes" in opts
    check ("UserKnownHostsFile=" & o.knownHosts) in opts
    check "GlobalKnownHostsFile=/dev/null" in opts

  removeDir(dir)
