## Omarchy, the configuration layer on Arch that add-on mode treats as a third
## owner (spec ReproOS-Add-On-Mode §4.3.2): how the add-on recognises an
## Omarchy base, reads its version, and checks the account the profile names
## as the one Omarchy runs as (``addOn { omarchyAccount = "<name>" }``, §8.5;
## §13 decision 94).
##
## The version comes from ``os-release`` (``VERSION_ID``, ``BUILD_ID``) and
## the installed ``omarchy`` package's ``%VERSION%`` in pacman's local
## database -- what ``omarchy-version`` reports -- and never from
## ``~/.local/share/omarchy/version``, which is a file reached through a link
## into ``/usr/share/omarchy`` and can be stale (measured on Omarchy 4.0.6).
##
## The account's home is read from the password database (``getpwnam(3)``),
## never from ``$HOME``: the add-on runs as root, and whose home holds the
## hook is a property of the account, not of the shell that ran the command.
## Everything here only reads.

import std/[os, posix, strutils, tables]

import repro_infra/addon_diagnostics

import ./pacman_db

const
  OmarchyId* = "omarchy"
    ## ``os-release`` ``ID`` of an Omarchy base (with ``ID_LIKE=arch``).
  OmarchyPackage* = "omarchy"
    ## The package holding Omarchy's scripts, whose version is Omarchy's.
  OmarchyHooksRel* = ".config/omarchy/hooks"
    ## Omarchy's hook directory, relative to the account's home
    ## (``omarchy-hook`` runs ``post-update.d/*`` from it).

type
  OmarchyFacts* = object
    ## What the preflight records about an Omarchy base.
    versionId*: string        ## ``os-release`` ``VERSION_ID``
    buildId*: string          ## ``os-release`` ``BUILD_ID``
    packageVersion*: string   ## the ``omarchy`` package's ``%VERSION%``

proc isOmarchyBase*(id: string): bool =
  ## ``ID=omarchy`` (spec §4.3.2). An Arch host that merely has some
  ## Omarchy package installed is not an Omarchy base.
  id.toLowerAscii() == OmarchyId

proc omarchyFacts*(osRelease: Table[string, string]; root = "/"): OmarchyFacts =
  ## Read-only: ``os-release`` and pacman's local database.
  OmarchyFacts(versionId: osRelease.getOrDefault("VERSION_ID"),
               buildId: osRelease.getOrDefault("BUILD_ID"),
               packageVersion: pacmanInstalledVersion(OmarchyPackage, root))

proc accountHome*(name: string): tuple[found: bool; home: string] =
  ## The home directory the password database records for ``name``.
  let pw = getpwnam(name.cstring)
  if pw == nil: return (false, "")
  (true, $pw.pw_dir)

proc omarchyHooksDir*(home: string): string =
  ## ``<home>/.config/omarchy/hooks``.
  home / OmarchyHooksRel

proc isRealDirectory(path: string): bool =
  ## A directory at ``path`` itself, not a symbolic link to one.
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode)

type
  OmarchyAccountProblem* = object
    ## Why the profile's ``omarchyAccount`` cannot stand on this base;
    ## ``detail`` "" when it can.
    diagnostic*: AddOnDiagnostic
    detail*: string

proc omarchyAccountProblem*(baseId, account: string;
                            lookup: proc(name: string): tuple[found: bool;
                              home: string] = accountHome):
    OmarchyAccountProblem =
  ## The profile's ``omarchyAccount`` against the base (spec §8.5; §13
  ## decisions 94 and 101):
  ##
  ## * an Omarchy base with no ``omarchyAccount``, an account the password
  ##   database does not know, or one whose home has no Omarchy hook
  ##   directory: ``EAddOnBaseLayerOwned`` (§8.4), naming what is missing;
  ## * an ``omarchyAccount`` on a base that is not Omarchy:
  ##   ``EAddOnOutOfScope`` -- the setting has no meaning there.
  ##
  ## ``lookup`` replaces the password database in the unit tests.
  template refuse(d: AddOnDiagnostic; why: string) =
    return OmarchyAccountProblem(diagnostic: d, detail: why)
  if not isOmarchyBase(baseId):
    if account.len > 0:
      refuse(adOutOfScope, "addOn.omarchyAccount \"" & account & "\" is " &
        "declared, but the base is ID=" & baseId & ", not Omarchy; the " &
        "setting names the account Omarchy runs as and is refused on any " &
        "other base (spec §8.5)")
    return
  if account.len == 0:
    refuse(adBaseLayerOwned, "the base is Omarchy and the profile names no " &
      "`addOn { omarchyAccount = \"<name>\" }`: the account Omarchy runs " &
      "as, whose home holds Omarchy's hook directory, must be declared " &
      "(spec §4.3.2, §8.5)")
  let (found, home) = lookup(account)
  if not found:
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\" is not " &
      "an account in the password database")
  if home.len == 0 or not home.isAbsolute:
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\" has no " &
      "absolute home directory in the password database ('" & home & "')")
  let hooks = omarchyHooksDir(home)
  if not isRealDirectory(hooks):
    refuse(adBaseLayerOwned, "omarchyAccount \"" & account & "\": " &
      hooks & " is not a directory; Omarchy's hook directory must exist " &
      "in the account's home (spec §4.3.2)")

proc omarchyAccountChecked*(purpose: string; recordOnly,
                            operatorProfile: bool): bool =
  ## Whether an apply checks the profile's ``omarchyAccount`` against the
  ## base (spec §8.5): on an operator profile's apply, and not on generation
  ## 0 alone (bootstrap's apply carries no operator profile), a replay, a
  ## revert or a record-only pass, which finish or undo a switch already
  ## decided and are never refused for the base.
  operatorProfile and purpose notin ["revert", "replay"] and not recordOnly

proc omarchyAccountRefusal*(baseId, account: string;
                            lookup: proc(name: string): tuple[found: bool;
                              home: string] = accountHome): string =
  ## ``omarchyAccountProblem`` as one message starting with its
  ## diagnostic's name, or "".
  let p = omarchyAccountProblem(baseId, account, lookup)
  if p.detail.len == 0: "" else: diagnosticMessage(p.diagnostic, p.detail)
