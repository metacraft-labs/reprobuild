## GM4c test fixtures: real macOS application bundles and the archives that
## deliver them, built at test time with the system tools.
##
## A fixture bundle is a genuine ``.app``: an ``Info.plist``, a Mach-O main
## executable compiled from C with ``/usr/bin/cc``, a sealed resource, and a
## real code signature made by ``/usr/bin/codesign``. The signature is
## AD-HOC (``-s -``) carrying a team identifier (``--team-identifier``):
## nothing built at test time can be signed by an Apple Developer ID
## certificate or notarized, and a self-signed certificate cannot set a team
## identifier at all (codesign records one only for Apple-issued
## certificates). So these bundles exercise every trust check whose input a
## test can produce for real — Info.plist identity, ``codesign --verify
## --deep --strict``, the team equality — and fail the two that need Apple
## (the Developer ID chain, notarization), which tests either assert as real
## refusals or relax through ``AppTrustPolicy``.
##
## Installer applications (Store-And-Installation-Layout.md § Installer
## applications) are built the same way: ``makeFixtureProductFolder`` makes
## the folder an installer produces (a main bundle, a second top-level
## bundle, a bundle nested in a hidden support directory and a plain file,
## the OpenWebStart layout), and ``makeFixtureInstallerApp`` a signed
## installer bundle that carries that folder in its ``Resources`` and copies
## it to the directory named by ``-dir`` when run -- install4j's unattended
## protocol (``-q -dir <d>``). Its main executable is a shell script, so a
## test can make the installer misbehave in a precise way (write outside its
## prefix, write a preference, open a connection, exit without installing)
## by passing ``extraScript``.
##
## The archives are made with the tools vendors use: ``hdiutil create``
## (HFS+ or APFS disk images, with the ``Applications -> /Applications``
## symlink a vendor image carries), ``ditto -c -k`` (zip), ``pkgbuild`` +
## ``productbuild`` (a flat product archive), and ``hdiutil udifrez`` (a
## software licence agreement on an image).
##
## macOS only; every proc raises ``OSError`` naming the failed command.

import std/[base64, os, osproc, streams, strutils]
from repro_core/ambient_execution import uncontrolledStartProcess

const
  FixtureTeamId* = "RPBTEST123"
    ## The team identifier fixture bundles are signed with. Valid shape (ten
    ## upper-case letters and digits); not a real team.

proc runArgv(exe: string; args: openArray[string]; workingDir = ""):
    tuple[output: string; exitCode: int] =
  ## Run the system tool ``exe`` (an absolute path) with an argument vector:
  ## no shell, so fixture paths are never re-parsed.
  let p = uncontrolledStartProcess(exe, workingDir = workingDir,
    args = @args, options = {poStdErrToStdOut})
  try:
    p.inputStream.close()
    result.output = p.outputStream.readAll()
    result.exitCode = p.waitForExit()
  finally:
    p.close()

proc runChecked(exe: string; args: openArray[string]; workingDir = "") =
  let res = runArgv(exe, args, workingDir)
  if res.exitCode != 0:
    raise newException(OSError, "fixture command failed (exit " &
      $res.exitCode & "): " & exe & " " & args.join(" ") & "\n" & res.output)

proc makeFixtureApp*(dir, name, bundleId, version: string;
                     teamId = FixtureTeamId; sign = true;
                     declareExecutable = true): string =
  ## Build ``dir/<name>.app`` and return its path. ``version`` becomes both
  ## ``CFBundleShortVersionString`` and ``CFBundleVersion``; different
  ## versions therefore have different signatures (different code-directory
  ## hashes), which is what the rollback tests compare. With
  ## ``declareExecutable = false`` the ``CFBundleExecutable`` value is empty,
  ## as in DB Browser for SQLite's bundle: macOS then finds the main
  ## executable by the bundle's directory name.
  let app = dir / (name & ".app")
  let contents = app / "Contents"
  createDir(contents / "MacOS")
  createDir(contents / "Resources")
  writeFile(contents / "Info.plist",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
    "<plist version=\"1.0\"><dict>\n" &
    "<key>CFBundleIdentifier</key><string>" & bundleId & "</string>\n" &
    "<key>CFBundleName</key><string>" & name & "</string>\n" &
    "<key>CFBundleExecutable</key><string>" &
      (if declareExecutable: name else: "") & "</string>\n" &
    "<key>CFBundleShortVersionString</key><string>" & version &
      "</string>\n" &
    "<key>CFBundleVersion</key><string>" & version & "</string>\n" &
    "<key>CFBundlePackageType</key><string>APPL</string>\n" &
    "</dict></plist>\n")
  writeFile(contents / "Resources" / "payload.txt",
    "fixture payload " & name & " " & version & "\n")
  let source = dir / ("." & name & "-main.c")
  writeFile(source, "int main(void) { return 0; }\n")
  runChecked("/usr/bin/cc", ["-o", contents / "MacOS" / name, source])
  removeFile(source)
  if sign:
    runChecked("/usr/bin/codesign", ["--force", "-s", "-",
      "--team-identifier", teamId, app])
  app

proc makeFixtureProductFolder*(dir, item, mainName, bundleId, version: string;
                               teamId = FixtureTeamId;
                               helperTeamId = ""): string =
  ## Build ``dir/<item>``, the folder an installer application produces, and
  ## return its path: ``<mainName>.app`` (the product bundle, ``bundleId`` /
  ## ``version``), ``<item> Helper.app`` (another top-level bundle, signed by
  ## ``helperTeamId``, default ``teamId``), ``.support/<item> Update.app``
  ## (a bundle nested in a hidden directory, the way install4j keeps its
  ## updater in ``.install4j/``) and ``readme.txt`` (a file outside every
  ## bundle).
  result = dir / item
  createDir(result / ".support")
  discard makeFixtureApp(result, mainName, bundleId, version, teamId)
  discard makeFixtureApp(result, item & " Helper", bundleId & ".helper",
    version, if helperTeamId.len > 0: helperTeamId else: teamId)
  discard makeFixtureApp(result / ".support", item & " Update",
    bundleId & ".update", version, teamId)
  writeFile(result / "readme.txt", item & " " & version & "\n")

proc makeFixtureInstallerApp*(dir, name, payload: string;
                              teamId = FixtureTeamId;
                              extraScript = ""; install = true): string =
  ## Build ``dir/<name>.app``, an ad-hoc signed installer application whose
  ## ``Resources/payload/<leaf>`` is a copy of ``payload`` (a product folder
  ## or bundle; "" for none), and return its path. Its main executable is a
  ## ``/bin/sh`` script implementing the subset of install4j's unattended
  ## protocol the realizer uses: ``-dir <d>`` names the installation
  ## directory, which it creates by copying the payload there with
  ## ``ditto``; ``-q`` and unknown options are ignored. Two more options let
  ## ``extraScript`` misbehave on request: ``-outside <path>`` and
  ## ``-report <file>`` set ``$outside`` and ``$report``. ``extraScript``
  ## runs after the arguments are parsed and before the copy; with
  ## ``install = false`` the script exits 0 without copying anything.
  let app = dir / (name & ".app")
  let contents = app / "Contents"
  createDir(contents / "MacOS")
  createDir(contents / "Resources" / "payload")
  writeFile(contents / "Info.plist",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
    "<plist version=\"1.0\"><dict>\n" &
    "<key>CFBundleIdentifier</key><string>dev.reprobuild.fixture.installer" &
      "</string>\n" &
    "<key>CFBundleName</key><string>" & name & "</string>\n" &
    "<key>CFBundleExecutable</key><string>install</string>\n" &
    "<key>CFBundleShortVersionString</key><string>1.0</string>\n" &
    "<key>CFBundleVersion</key><string>1.0</string>\n" &
    "<key>CFBundlePackageType</key><string>APPL</string>\n" &
    "</dict></plist>\n")
  if payload.len > 0:
    runChecked("/usr/bin/ditto", [payload, contents / "Resources" /
      "payload" / extractFilename(payload)])
  else:
    writeFile(contents / "Resources" / "payload" / ".empty", "")
  let exe = contents / "MacOS" / "install"
  writeFile(exe, "#!/bin/sh\n" &
    "# Reprobuild fixture installer (install4j's -q -dir protocol).\n" &
    "payload=\"$(cd \"$(dirname \"$0\")/../Resources/payload\" && pwd)\"\n" &
    "dest=''; outside=''; report=''\n" &
    "while [ $# -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    -dir) dest=\"$2\"; shift 2 ;;\n" &
    "    -outside) outside=\"$2\"; shift 2 ;;\n" &
    "    -report) report=\"$2\"; shift 2 ;;\n" &
    "    *) shift ;;\n" &
    "  esac\n" &
    "done\n" &
    "if [ -z \"$dest\" ]; then echo 'fixture installer: no -dir' >&2; " &
      "exit 2; fi\n" &
    extraScript & "\n" &
    (if install:
       "for item in \"$payload\"/*; do\n" &
       "  [ -e \"$item\" ] || continue\n" &
       "  /usr/bin/ditto \"$item\" \"$dest\" || exit 4\n" &
       "done\n" &
       "echo \"fixture installer: installed into $dest\"\n"
     else:
       "echo 'fixture installer: installing nothing'\n") &
    "exit 0\n")
  setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  runChecked("/usr/bin/codesign", ["--force", "-s", "-",
    "--team-identifier", teamId, app])
  app

proc tamperFixtureApp*(app: string) =
  ## Change a sealed resource AFTER signing, the way a modified download
  ## looks: ``codesign --verify`` then reports "a sealed resource is missing
  ## or invalid".
  writeFile(app / "Contents" / "Resources" / "payload.txt", "tampered\n")

proc makeFixtureDmg*(dir, dmgName: string; apps: openArray[string];
                     fs = "HFS+"): string =
  ## A compressed (UDZO) disk image holding copies of ``apps`` and the
  ## ``Applications`` symlink vendor images carry. ``fs`` is ``HFS+`` or
  ## ``APFS``.
  let volume = dir / ("." & dmgName & ".volume")
  removeDir(volume)
  createDir(volume)
  for app in apps:
    runChecked("/usr/bin/ditto", [app, volume / extractFilename(app)])
  createSymlink("/Applications", volume / "Applications")
  result = dir / dmgName
  runChecked("/usr/bin/hdiutil", ["create", "-quiet", "-ov", "-fs", fs,
    "-format", "UDZO", "-volname", dmgName.changeFileExt(""),
    "-srcfolder", volume, result])
  removeDir(volume)

proc makeFixtureZip*(dir, zipName, app: string): string =
  ## A zip of ``app`` (with its directory) the way vendors make them.
  result = dir / zipName
  runChecked("/usr/bin/ditto", ["-c", "-k", "--keepParent",
    extractFilename(app), result], workingDir = app.parentDir)

proc makeFixturePkg*(dir, pkgName, componentName, app: string): string =
  ## A flat product archive whose component ``componentName`` installs
  ## ``app`` into ``/Applications``. Nothing ever installs it: tests only
  ## expand it.
  let root = dir / ("." & pkgName & ".root")
  removeDir(root)
  createDir(root / "Applications")
  runChecked("/usr/bin/ditto", [app, root / "Applications" /
    extractFilename(app)])
  let component = dir / componentName
  runChecked("/usr/bin/pkgbuild", ["--quiet", "--root", root,
    "--identifier", "dev.reprobuild.fixture." &
      componentName.changeFileExt(""),
    "--version", "1.0", "--install-location", "/", component])
  result = dir / pkgName
  runChecked("/usr/bin/productbuild", ["--quiet", "--package", component,
    result])
  removeFile(component)
  removeDir(root)

proc addLicenceAgreement*(dmg: string) =
  ## Attach a software licence agreement to ``dmg`` (the ``LPic`` / ``STR#``
  ## / ``TEXT`` resources ``hdiutil attach`` presents before mounting),
  ## through ``hdiutil udifrez``. The resource layout is create-dmg's EULA
  ## template (https://github.com/create-dmg/create-dmg,
  ## ``support/eula-resources-template.xml``).
  let xml = dmg & ".sla.xml"
  writeFile(xml, """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LPic</key>
	<array>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
			AAAAAgAAAAAAAAAAAAQAAA==
			</data>
			<key>ID</key>
			<string>5000</string>
			<key>Name</key>
			<string></string>
		</dict>
	</array>
	<key>STR#</key>
	<array>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
			AAYNRW5nbGlzaCB0ZXN0MQVBZ3JlZQhEaXNhZ3JlZQVQcmludAdT
			YXZlLi4ueklmIHlvdSBhZ3JlZSB3aXRoIHRoZSB0ZXJtcyBvZiB0
			aGlzIGxpY2Vuc2UsIGNsaWNrICJBZ3JlZSIgdG8gYWNjZXNzIHRo
			ZSBzb2Z0d2FyZS4gSWYgeW91IGRvIG5vdCBhZ3JlZSwgY2xpY2sg
			IkRpc2FncmVlIi4=
			</data>
			<key>ID</key>
			<string>5000</string>
			<key>Name</key>
			<string>English buttons</string>
		</dict>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
			AAYHRW5nbGlzaAVBZ3JlZQhEaXNhZ3JlZQVQcmludAdTYXZlLi4u
			e0lmIHlvdSBhZ3JlZSB3aXRoIHRoZSB0ZXJtcyBvZiB0aGlzIGxp
			Y2Vuc2UsIHByZXNzICJBZ3JlZSIgdG8gaW5zdGFsbCB0aGUgc29m
			dHdhcmUuIElmIHlvdSBkbyBub3QgYWdyZWUsIGNsaWNrICJEaXNh
			Z3JlZSIu
			</data>
			<key>ID</key>
			<string>5002</string>
			<key>Name</key>
			<string>English</string>
		</dict>
	</array>
	<key>TEXT</key>
	<array>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
""" &
    encode("Reprobuild fixture licence agreement.\n") & """
			</data>
			<key>ID</key>
			<string>5000</string>
			<key>Name</key>
			<string>English</string>
		</dict>
	</array>
	<key>TMPL</key>
	<array>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
			E0RlZmF1bHQgTGFuZ3VhZ2UgSUREV1JEBUNvdW50T0NOVAQqKioq
			TFNUQwtzeXMgbGFuZyBJRERXUkQebG9jYWwgcmVzIElEIChvZmZz
			ZXQgZnJvbSA1MDAwRFdSRBAyLWJ5dGUgbGFuZ3VhZ2U/RFdSRAQq
			KioqTFNURQ==
			</data>
			<key>ID</key>
			<string>128</string>
			<key>Name</key>
			<string>LPic</string>
		</dict>
	</array>
	<key>styl</key>
	<array>
		<dict>
			<key>Attributes</key>
			<string>0x0000</string>
			<key>Data</key>
			<data>
			AAMAAAAAAAwACQAUAAAAAAAAAAAAAAAAACcADAAJABQBAAAAAAAA
			AAAAAAAAKgAMAAkAFAAAAAAAAAAAAAA=
			</data>
			<key>ID</key>
			<string>5000</string>
			<key>Name</key>
			<string>English</string>
		</dict>
	</array>
</dict>
</plist>
""")
  runChecked("/usr/bin/hdiutil", ["udifrez", "-xml", xml, "", "-quiet", dmg])
  removeFile(xml)

proc sha256Of*(path: string): string =
  ## Lower-case hex SHA-256 of ``path`` through ``shasum``.
  let res = runArgv("/usr/bin/shasum", ["-a", "256", path])
  if res.exitCode != 0:
    raise newException(OSError, "shasum failed: " & res.output)
  res.output.splitWhitespace()[0].toLowerAscii()

proc plistValue*(app, key: string): string =
  ## One string value of ``app``'s Info.plist (read with ``plutil``).
  let res = runArgv("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-",
    app / "Contents" / "Info.plist"])
  if res.exitCode != 0:
    return ""
  res.output.strip()
