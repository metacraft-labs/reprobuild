## Steps the AR6 gates share (milestone AR6, "Living under pacman and Omarchy
## updates"; spec ReproOS-Add-On-Mode §4.3.1, §4.3.2, §7.8, §7.9): the
## profile with the fixture services, the ALPM and Omarchy hooks' records,
## and what a plan says about the base.
##
## *Mocking.* None: everything here reads the real guest.

import std/[os, strutils, tables]

import ./addon_testbed
import ./arch_gate_support
import ./upgrade_support

const
  AlpmHookPathInGuest* = "/etc/pacman.d/hooks/90-repro-addon.hook"
  AlpmHookLog* = "/var/lib/repro/system/addon/alpm-hook.log"
  AlpmHookTag* = "repro-addon-alpm-hook"
  OmarchyHookLog* = "/var/lib/repro/system/addon/omarchy-hook.log"
  OmarchyHookTag* = "repro-addon-omarchy-hook"
  SecondUnitName* = "repro-addon-fixture-2.service"
  FixtureServices* = [FixtureUnitName, SecondUnitName]

proc secondFixtureUnit*(reproExe: string): string =
  ## A second store-package service beside ``fixtureUnit`` (the add-on's
  ## own ``repro`` again: the only store package every add-on host has,
  ## spec §8.3 *Services on Arch*).
  "systemd.systemUnit {\n" &
  "  floorExceptions = [\"serviceFloor: a test fixture whose only job is " &
    "to stay active\"]\n" &
  "  name = \"" & SecondUnitName & "\"\n" &
  "  content = \"[Unit]\nDescription=Reprobuild add-on Arch test fixture 2\n\n" &
    "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=" & reproExe &
    " --version\n\n[Install]\nWantedBy=repro-addon.target\n\"\n" &
  "  enabled = true\n}\n"

proc servicesProfile*(reproExe: string; omarchyAccount = ""): string =
  ## Generation 1 of the update gates: two fixture services and a file.
  gen1Profile(reproExe, omarchyAccount) & "\n" & secondFixtureUnit(reproExe)

proc servicesState*(g: Guest): Table[string, tuple[active, invocation: string]] =
  for u in FixtureServices:
    let s = g.serviceState(u)
    result[u] = (s.active, s.invocation)

proc servicesUnchanged*(before, now: Table[string, tuple[active, invocation: string]]):
    tuple[ok: bool; detail: string] =
  ## Every fixture service still active, in the invocation it had.
  result.ok = true
  for u, s in before:
    let n = now.getOrDefault(u)
    let same = n.active == "active" and n.invocation == s.invocation and
               s.invocation.len > 0
    result.ok = result.ok and same
    result.detail.add(u & ": " & s.active & " " & s.invocation & " -> " &
      n.active & " " & n.invocation & "\n")

proc logLines*(g: Guest; path: string): seq[string] =
  for l in g.exec("cat " & path & " 2>/dev/null").stdout.splitLines():
    if l.strip().len > 0: result.add(l)

proc journalOf*(g: Guest; tag: string): string =
  g.exec("journalctl -o cat --no-pager -t " & tag).stdout

proc planBaseLine*(planOutput: string): string =
  ## The plan's ``base:`` line (``cli.renderPlan``).
  for l in planOutput.splitLines():
    if l.startsWith("base: "): return l
  ""

proc systemdMajorOf*(version: string): string =
  ## ``262-1`` / ``261.3-1`` -> ``262`` / ``261``.
  version.split('-')[0].split('.')[0]

proc symlinkTargetIs*(g: Guest; path, target: string): bool =
  ## ``path`` is a symbolic link to exactly ``target``.
  g.exec("test -L " & path).exitCode == 0 and
    g.run("readlink " & path).strip() == target

# ---------------------------------------------------------------------------
# The second Omarchy version (spec §12.1, §13 decision 93; decided for AR6 by
# the operator on 2026-11-23: derived in the test bed while Omarchy serves no
# release after the pinned one).
# ---------------------------------------------------------------------------

const
  OmarchySecondVersion* = "4.5.0-4"
    ## The test bed's second Omarchy version: the captured 4.5.0-3 package
    ## rebuilt (``deriveOmarchyRecipe``). Omarchy's repository kept only
    ## 4.5.0-3 when AR6 was measured (its stable, edge and rc channels,
    ## 2026-11-23), so no later release could be captured; a real capture
    ## replaces this one when Omarchy publishes one.
  OmarchyFixtureMigration* = "/usr/share/omarchy/migrations/1799999999.sh"
    ## The fixture migration the second version adds: it appends to the
    ## generation's fixture unit file (a ledger path) through ``sudo tee
    ## -a``, as Omarchy's migrations write ``/etc``, and so names it. A unit
    ## file, because the add-on writes unit files as copies: an
    ## ``fs.systemFile`` is a link into the read-only store, through which
    ## the migration's write fails and ``omarchy update`` stops (measured
    ## 2026-11-23; reprobuild-pm issue
    ## ``2026-11-23-an-omarchy-migration-writing-a-link-form-ledger-path-stops-omarchy-update``).
  OmarchyFixtureUnitPath* = "/etc/systemd/system/" & FixtureUnitName
  OmarchyDroppedPath* = "/etc/fido2"
    ## The path (with ``/etc/fido2/fido2``) the second version's scripts no
    ## longer name: its two migrations name a renamed directory instead.
  OmarchyDerivedRoot* = "/var/cache/repro-testbed/derived"
    ## In the guest: the derived ``[omarchy]`` repository (every captured
    ## package of the repository and the rebuilt one), a ``file://`` server.
  OmarchyDerivedMtime* = 1793848468
    ## Every file of the rebuilt package carries this mtime (4.5.0-3's
    ## ``builddate``), so two derivations make the same bytes.
  OmarchyDerivedPinFile* = currentSourcePath().parentDir / "fixtures" /
    "omarchy" / ("omarchy-" & OmarchySecondVersion & ".derived")
    ## The derived package's SHA-256, committed: a derivation that makes
    ## other bytes is refused (pinned by content, like the capture).

proc omarchyDerivedPin*(): string =
  ## The committed SHA-256 of the derived package ("" when none is).
  for l in readFile(OmarchyDerivedPinFile).splitLines():
    let t = l.strip()
    if t.len == 64 and not t.startsWith("#"): return t
  ""

proc deriveOmarchyRecipe*(captureRoot: string): string =
  ## Run as root in the Omarchy guest: rebuild the captured omarchy package
  ## as ``OmarchySecondVersion`` the way makepkg packages one
  ## (makepkg(8)'s ``create_package``: ``.MTREE`` over every file, then
  ## ``.MTREE``, ``.PKGINFO`` and the tree in one archive), with every name
  ## listed in byte order and every mtime ``OmarchyDerivedMtime``. Prints
  ## the package's path and SHA-256.
  let src = captureRoot & "/omarchy/omarchy-4.5.0-3-x86_64.pkg.tar.zst"
  let dst = OmarchyDerivedRoot & "/omarchy-" & OmarchySecondVersion &
            "-x86_64.pkg.tar.zst"
  "set -eu\n" &
  "w=/var/tmp/repro-derive; rm -rf $w; mkdir -p $w/root " & OmarchyDerivedRoot & "\n" &
  "cd $w/root\n" &
  "bsdtar -xpf " & src & "\n" &
  "sed -i 's#" & OmarchyDroppedPath & "#/etc/repro-gate-moved-fido2#g' " &
    "usr/share/omarchy/migrations/1787494718.sh " &
    "usr/share/omarchy/migrations/1788256455.sh\n" &
  "! grep -rq '" & OmarchyDroppedPath & "' usr/share/omarchy/install usr/share/omarchy/migrations\n" &
  "cat > ." & OmarchyFixtureMigration & " <<'REPRO_EOF'\n" &
  "# The Reprobuild test bed's fixture migration (Omarchy " &
    OmarchySecondVersion & ", derived): it writes a path the add-on owns.\n" &
  "echo '# written by the fixture migration' | sudo tee -a " &
    OmarchyFixtureUnitPath & " >/dev/null\n" &
  "REPRO_EOF\n" &
  "chmod 0644 ." & OmarchyFixtureMigration & "\n" &
  "sed -i 's/^pkgver = 4.5.0-3$/pkgver = " & OmarchySecondVersion & "/' .PKGINFO\n" &
  "grep -qx 'pkgver = " & OmarchySecondVersion & "' .PKGINFO\n" &
  "rm -f .MTREE\n" &
  "find . -mindepth 1 -exec touch -h -d @" & $OmarchyDerivedMtime & " {} +\n" &
  "find . -mindepth 1 -printf '%P\\0' | LC_ALL=C sort -z > $w/list\n" &
  "LANG=C bsdtar -cf - --format=mtree --null -n -T $w/list " &
    "--options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' " &
    "| gzip -n -9 > .MTREE\n" &
  "touch -h -d @" & $OmarchyDerivedMtime & " .MTREE\n" &
  "{ printf '.MTREE\\0'; cat $w/list; } > $w/list2\n" &
  "LANG=C bsdtar -cf - --null -n -T $w/list2 | zstd -q -19 -T1 -c > " & dst & "\n" &
  "echo " & dst & "\n" &
  "sha256sum " & dst & " | cut -d' ' -f1\n"

proc derivedRepoRecipe*(captureRoot: string): string =
  ## Run as root after ``deriveOmarchyRecipe``: sign the rebuilt package
  ## with a key the test bed makes and pacman's keyring trusts locally (the
  ## repository's ``SigLevel`` is ``Required``), and make the derived
  ## ``[omarchy]`` repository -- the captured one with the rebuilt package
  ## added (``repo-add`` replaces 4.5.0-3's entry).
  let pkg = OmarchyDerivedRoot & "/omarchy-" & OmarchySecondVersion &
            "-x86_64.pkg.tar.zst"
  "set -eu\n" &
  "d=" & OmarchyDerivedRoot & "; k=/var/tmp/repro-derive/gnupg\n" &
  "mkdir -p -m 0700 $k\n" &
  "gpg --homedir $k --batch --passphrase '' --quick-gen-key " &
    "'Reprobuild test bed <testbed@invalid>' ed25519 sign never 2>/dev/null\n" &
  "fpr=$(gpg --homedir $k --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')\n" &
  "gpg --homedir $k --armor --export $fpr > /var/tmp/repro-derive/testbed.asc\n" &
  "pacman-key --add /var/tmp/repro-derive/testbed.asc >/dev/null 2>&1\n" &
  "pacman-key --lsign-key $fpr >/dev/null 2>&1\n" &
  "gpg --homedir $k --batch --detach-sign --no-armor -o " & pkg & ".sig " & pkg & "\n" &
  "for f in " & captureRoot & "/omarchy/*.pkg.tar.zst*; do ln -f \"$f\" $d/ 2>/dev/null || cp \"$f\" $d/; done\n" &
  "cp " & captureRoot & "/omarchy/omarchy.db $d/omarchy.db.tar.zst\n" &
  "repo-add -q $d/omarchy.db.tar.zst " & pkg & "\n" &
  "rm -f $d/omarchy.db $d/omarchy.db.tar.zst.old; mv $d/omarchy.db.tar.zst $d/omarchy.db\n" &
  "tar -tf $d/omarchy.db | grep -qx 'omarchy-" & OmarchySecondVersion & "/'\n" &
  "echo $fpr\n"
