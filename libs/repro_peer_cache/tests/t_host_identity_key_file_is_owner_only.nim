## A host-identity private-key file is readable by its owner only, on every
## platform (deployment-security-architecture.md CRED-3), and it round-trips.
##
## On POSIX the writers create the file `O_CREAT|O_EXCL` with mode 0600. On
## Windows a file has no mode: its DACL decides who may open it, and a new
## file inherits the directory's. Until M17 chunk 2 the Windows branches
## could not write a host CA key at all (`writeKeyFileSecure` called
## `writeCertAndKey` with an empty certificate path) and could not read one
## (`loadCertAndKey("")`), and `writeCertAndKey` itself created the key file
## with the inherited DACL and then called `setFilePermissions`, which on
## Windows only toggles the read-only attribute. Now both writers create the
## file with a protected DACL holding only the current user
## (`owner_only_file.nim`).
##
## What is checked, per platform, through an API independent of the writer
## (`stat` on POSIX, `GetNamedSecurityInfoW` on Windows):
##
##   * the host CA key minted by `loadOrCreateHostIdentity` is owner-only;
##   * it reads back: a second `loadOrCreateHostIdentity` yields the same
##     host id (the reader re-derives the public key from the private scalar
##     and refuses a mismatch), and the reloaded key can still mint a leaf
##     that verifies under the pinned CA;
##   * `writeCertAndKey` produces an owner-only key that `loadCertAndKey`
##     reads back, also when it replaces a file that had broader access;
##   * control: a file created the ordinary way in the same directory is NOT
##     owner-only, so the check discriminates;
##   * Windows: the create refuses a DANGLING symbolic link planted at the
##     path, as `open(O_CREAT|O_EXCL)` does on POSIX, and writes nothing
##     where the link points. Added by the independent verification of M17
##     chunk 2: `CreateFileW(CREATE_NEW)` alone follows such a link and
##     creates its target (measured), so a link planted between the writer's
##     removal of the old file and its create put the key at the link's
##     target. Falsifier: dropping `FILE_FLAG_OPEN_REPARSE_POINT` from the
##     create turns the case red.
##
## MOCK POLICY — none: real files, real ACLs / modes, real keys.

import std/[os, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix

import repro_peer_cache
import repro_test_support/reasoned_skip
when defined(windows):
  import repro_peer_cache/owner_only_file

proc ownerOnlyViolation(path: string): string =
  ## "" when `path` is owner-only by this platform's rule.
  when defined(windows):
    ownerOnlyAclViolation(path)
  else:
    var st: Stat
    if stat(path.cstring, st) != 0:
      return "cannot stat " & path
    let mode = int(st.st_mode) and 0o777
    if mode != 0o600:
      return "mode is " & toOct(mode, 3) & ", not 600"
    if st.st_uid != getuid():
      return "the file is not owned by the current user"
    ""

suite "M17 chunk 2: host-identity key files are owner-only on every platform":

  test "the host CA key is created owner-only and reads back":
    let base = createTempDir("m17-keyfile-", "")
    defer: removeDir(base)
    let certPath = base / "id" / "host-ca.crt"
    let keyPath = base / "id" / "host-ca.key"
    let first = loadOrCreateHostIdentity(certPath, keyPath)
    check fileExists(keyPath)
    check ownerOnlyViolation(keyPath) == ""
    let second = loadOrCreateHostIdentity(certPath, keyPath)
    check second.hostId == first.hostId
    check second.ca.keypair.publicKey == first.ca.keypair.publicKey
    # The reloaded private scalar is the CA's: a leaf it mints verifies
    # under the CA pinned from the first run.
    let anchorDir = base / "anchors"
    createDir(anchorDir)
    writeFile(anchorDir / "a.crt", first.ca.certPem)
    let anchors = loadTrustAnchorDir(anchorDir)
    let leaf = second.mintLeaf(lrDaemon)
    let verified = verifyLeaf(leaf.cert.certDer, anchors, getTime().toUnix)
    check verified.ok
    check verified.hostId == first.hostId

  test "a corrupted key file is refused, not silently replaced":
    let base = createTempDir("m17-keyfile-", "")
    defer: removeDir(base)
    let certPath = base / "host-ca.crt"
    let keyPath = base / "host-ca.key"
    discard loadOrCreateHostIdentity(certPath, keyPath)
    removeFile(keyPath)
    writeFile(keyPath, "ecdsa-p256:" & "zz".repeat(32) & "\n")
    expect IdentityError:
      discard loadOrCreateHostIdentity(certPath, keyPath)

  test "writeCertAndKey writes an owner-only key that loadCertAndKey reads":
    let base = createTempDir("m17-keyfile-", "")
    defer: removeDir(base)
    let certPath = base / "peer.crt"
    let keyPath = base / "peer.key"
    # A previous file with ordinary (broader) access is replaced, not reused.
    writeFile(keyPath, "stale")
    let ck = generateSelfSignedCert(generateKeypair(), "m17-keyfile")
    writeCertAndKey(ck, certPath, keyPath)
    check ownerOnlyViolation(keyPath) == ""
    let back = loadCertAndKey(certPath, keyPath)
    check back.keypair.publicKey == ck.keypair.publicKey
    check back.keypair.privateKey == ck.keypair.privateKey

  test "control: an ordinarily created file is not owner-only":
    let base = createTempDir("m17-keyfile-", "")
    defer: removeDir(base)
    let plain = base / "plain.txt"
    writeFile(plain, "x")
    when defined(posix):
      # Make the control independent of the umask.
      discard chmod(plain.cstring, Mode(0o644))
    check ownerOnlyViolation(plain) != ""

  test "the create refuses a dangling symbolic link at the path":
    when defined(windows):
      let base = createTempDir("m17-keyfile-", "")
      defer: removeDir(base)
      let keyPath = base / "host-ca.key"
      let target = base / "elsewhere" / "planted.key"
      createDir(base / "elsewhere")
      var linked = true
      try:
        createSymlink(target, keyPath)
      except OSError:
        linked = false
      if not linked:
        skip("this account may not create symbolic links (no developer " &
          "mode or SeCreateSymbolicLinkPrivilege), so no link can be " &
          "planted at the key path")
      else:
        require symlinkExists(keyPath)
        require not fileExists(target)
        # The window between the writer's removal of an old file and its
        # create: something planted a link there. `createNewOwnerOnlyFile`
        # is that create.
        expect OwnerOnlyFileError:
          createNewOwnerOnlyFile(keyPath, "ecdsa-p256:secret")
        check not fileExists(target)
        check symlinkExists(keyPath)
        # The writer itself removes the link and writes a regular file.
        createOwnerOnlyFile(keyPath, "ecdsa-p256:secret")
        check not symlinkExists(keyPath)
        check fileExists(keyPath)
        check not fileExists(target)
        check ownerOnlyViolation(keyPath) == ""
    else:
      skip("the POSIX writers create the key with open(O_CREAT|O_EXCL, " &
        "0600), which fails with EEXIST on any link at the path and never " &
        "follows it; the property is Windows' to prove")
