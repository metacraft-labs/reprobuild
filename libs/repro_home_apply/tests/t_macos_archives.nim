## GM4c: copying an application bundle out of a disk image, an installer
## package, a zip or a tarball — and never leaving a disk image attached
## (`repro_home_apply/macos_archives.nim`; Store-And-Installation-Layout.md
## § macOS Application Bundles, "Realization").
##
## Real tools, real archives, no mocks: every archive is built at test time
## with the tools vendors use (`hdiutil create` for HFS+ and APFS images,
## `ditto -c -k`, `pkgbuild` + `productbuild`, `tar`, and `hdiutil udifrez`
## for a licence agreement), and extraction runs `hdiutil attach/detach`,
## `pkgutil --expand-full`, `ditto` and `tar` for real.
##
## THE INVARIANT under test is that no failure path leaves a volume
## mounted. Each failing extraction is followed by a query of
## `hdiutil info` for attachments of THAT image (`attachedImagesOf`), which
## must be empty. The forced-detach fallback is exercised by holding a file
## on the mounted volume open, which makes an ordinary `hdiutil detach` fail
## with "resource busy" — the state a Spotlight indexer or a stray handle
## produces in practice.
##
## Falsifying mutation: removing the `finally` detach from
## `extractAppBundle`'s dmg branch fails every "nothing stays attached"
## check after a failing extraction.

when defined(macosx):
  import std/[os, osproc, strutils, tempfiles, unittest]

  import repro_home_apply/macos_archives
  import repro_home_resources/drivers/app_bundle
  import repro_test_support/macos_app_fixtures

  const
    FixtureId = "dev.reprobuild.gm4c.archives"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  proc verified(bundle: string): AppBundleIdentity =
    verifyAppBundle(bundle, AppBundleExpectation(bundleId: FixtureId,
      version: "1.0.0", teamId: FixtureTeamId), Relaxed)

  suite "GM4c: app bundles out of archives":
    let root = createTempDir("repro-gm4c-archives-", "")
    let app = makeFixtureApp(root / "src", "Fixture", FixtureId, "1.0.0")
    let expected = appBundleCanonicalBytes(readAppBundleIdentity(app))
    var counter = 0
    proc fresh(label: string): tuple[dest, scratch: string] =
      inc counter
      (root / ("dest-" & label & "-" & $counter),
       root / ("scratch-" & label & "-" & $counter))

    for fs in ["HFS+", "APFS"]:
      test "a " & fs & " disk image yields the intact bundle and is " &
          "detached":
        let dmg = makeFixtureDmg(root, "fixture-" & fs & ".dmg", [app], fs)
        let dirs = fresh(fs)
        let bundle = extractAppBundle(dmg, aakDmg, "Fixture.app", dirs.dest,
          dirs.scratch)
        check bundle == dirs.dest / "Fixture.app"
        check appBundleCanonicalBytes(verified(bundle)) == expected
        check attachedImagesOf(dmg).len == 0

    test "a missing bundle path fails naming what the image holds, and " &
        "the image is detached":
      let dmg = makeFixtureDmg(root, "missing.dmg", [app])
      let dirs = fresh("missing")
      try:
        discard extractAppBundle(dmg, aakDmg, "Other.app", dirs.dest,
          dirs.scratch)
        check false
      except EAppArchive as err:
        checkpoint err.msg
        check "Other.app" in err.msg
        check "Fixture.app" in err.msg
      check attachedImagesOf(dmg).len == 0
      check not dirExists(dirs.dest / "Other.app")

    test "a path through the image's Applications symlink is refused " &
        "(it would read the host's /Applications)":
      let dmg = makeFixtureDmg(root, "symlink.dmg", [app])
      let dirs = fresh("symlink")
      try:
        discard extractAppBundle(dmg, aakDmg, "Applications/Safari.app",
          dirs.dest, dirs.scratch)
        check false
      except EAppArchive as err:
        check "symlink" in err.msg
      check attachedImagesOf(dmg).len == 0

    test "a corrupt disk image fails to attach and nothing is attached":
      let dmg = root / "corrupt.dmg"
      writeFile(dmg, repeat("not a disk image", 4096))
      let dirs = fresh("corrupt")
      expect EAppArchive:
        discard extractAppBundle(dmg, aakDmg, "Fixture.app", dirs.dest,
          dirs.scratch)
      check attachedImagesOf(dmg).len == 0

    test "a disk image with a licence agreement is declined, not accepted":
      let dmg = makeFixtureDmg(root, "licence.dmg", [app])
      addLicenceAgreement(dmg)
      check hasLicenceAgreement(dmg)
      let dirs = fresh("licence")
      try:
        discard extractAppBundle(dmg, aakDmg, "Fixture.app", dirs.dest,
          dirs.scratch)
        check false
      except EAppArchive as err:
        checkpoint err.msg
        check "licence agreement" in err.msg
      check attachedImagesOf(dmg).len == 0
      check not dirExists(dirs.dest / "Fixture.app")

    test "a busy volume is detached by the forced fallback":
      let dmg = makeFixtureDmg(root, "busy.dmg", [app])
      let image = attachDmg(dmg, root / "busy-mnt")
      check attachedImagesOf(dmg).len == 1
      # Hold a file on the volume open: an ordinary detach now fails.
      var held = open(image.mountPoints[0] / "Fixture.app" / "Contents" /
        "Info.plist")
      try:
        let forced = detachDevice(image.device, dmg)
        check forced
      finally:
        held.close()
      check attachedImagesOf(dmg).len == 0

    test "a zip is expanded with ditto and keeps the signature intact":
      let zip = makeFixtureZip(root, "fixture.zip", app)
      let dirs = fresh("zip")
      let bundle = extractAppBundle(zip, aakZip, "Fixture.app", dirs.dest,
        dirs.scratch)
      check appBundleCanonicalBytes(verified(bundle)) == expected

    test "a gzip tarball yields the intact bundle":
      let tarball = root / "fixture.tar.gz"
      let res = execCmdEx("cd " & quoteShell(root / "src") &
        " && /usr/bin/tar -czf " & quoteShell(tarball) & " Fixture.app")
      check res.exitCode == 0
      let dirs = fresh("tar")
      let bundle = extractAppBundle(tarball, aakTar, "Fixture.app",
        dirs.dest, dirs.scratch)
      check appBundleCanonicalBytes(verified(bundle)) == expected

    test "a bundle in an installer package's payload is copied out " &
        "without running the package":
      let pkg = makeFixturePkg(root, "fixture.pkg", "component.pkg", app)
      let dirs = fresh("pkg")
      let bundle = extractAppBundle(pkg, aakPkg,
        "component.pkg/Payload/Applications/Fixture.app", dirs.dest,
        dirs.scratch)
      check bundle == dirs.dest / "Fixture.app"
      check appBundleCanonicalBytes(verified(bundle)) == expected

    test "a package on a disk image is expanded on the way to its bundle":
      let pkg = makeFixturePkg(root, "Nested.pkg", "inner.pkg", app)
      let vol = root / "nested-src"
      createDir(vol)
      moveFile(pkg, vol / "Nested.pkg")
      # `makeFixtureDmg` copies bundles; this image carries the package.
      let dmg = root / "nested.dmg"
      let res = execCmdEx("/usr/bin/hdiutil create -quiet -ov -fs HFS+ " &
        "-format UDZO -volname Nested -srcfolder " & quoteShell(vol) & " " &
        quoteShell(dmg))
      check res.exitCode == 0
      let dirs = fresh("nested")
      let bundle = extractAppBundle(dmg, aakDmg,
        "Nested.pkg/inner.pkg/Payload/Applications/Fixture.app", dirs.dest,
        dirs.scratch)
      check appBundleCanonicalBytes(verified(bundle)) == expected
      check attachedImagesOf(dmg).len == 0

    test "bundle paths that leave the archive are refused before any work":
      for bad in ["/Applications/Fixture.app", "../Fixture.app",
                  "Fixture.app/../x.app", "Fixture", ""]:
        expect ValueError:
          discard validateBundlePath(bad)

    removeDir(root)
