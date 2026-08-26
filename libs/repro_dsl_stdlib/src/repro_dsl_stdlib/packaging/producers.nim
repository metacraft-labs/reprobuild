## Per-format package producers — the ``.deb`` / ``.rpm`` / ``.tar.gz``
## build edges of the M0 packaging layer.
##
## Each producer is an ordinary content-addressed reprobuild build edge:
## a single ``shell(...)`` action whose command (a) stages the shared §5
## payload via ``renderPayloadStaging`` (encoded ONCE in
## ``install_tree.nim``), (b) wraps that payload in the format's own
## control/spec/metadata, and (c) invokes the backend tool
## (``dpkg-deb`` / ``rpmbuild`` / ``tar``). The action declares the
## component binaries + vendored libraries as ``extraInputs`` and the
## artifact as ``extraOutputs``, so the engine caches it on
## inputs + argv: a rebuild with unchanged sources cache-hits identically
## (M0 gate).
##
## The backend tools are threaded through the action's
## ``toolIdentityRefs`` (via ``appendRegisteredActionToolIdentityRefs``)
## so the engine's tool-identity resolver prepends the resolved bin dir
## to the action's PATH at fork time — the same mechanism
## ``expand_archive.nim`` uses. On a Debian/Fedora host with
## ``--tool-provisioning=path`` the tools resolve from the system PATH;
## with Nix provisioning they come from ``packages/{dpkg_deb,rpmbuild,tar}``.
##
## Scope (M0): ``.deb``, ``.rpm``, ``.tar.gz`` only. MSI / Scoop / .pkg /
## Homebrew / *BSD / AppImage / Nix are M1 — they slot in as additional
## producers over the SAME ``Distribution`` without reshaping this file.

import std/[os, strutils]

import repro_project_dsl
import ./install_tree

# Register the backend tool identities so ``uses:`` selectors and the
# ``toolIdentityRefs`` resolver bind them (mirrors expand_archive.nim's
# ``import ... as x; export x`` of its native tools).
import ../packages/sh as sh_module
import ../packages/tar as tar_module
import ../packages/dpkg_deb as dpkg_deb_module
import ../packages/rpmbuild as rpmbuild_module

export install_tree
export sh_module, tar_module, dpkg_deb_module, rpmbuild_module

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

proc stagingRoot(d: Distribution; format: string): string =
  ## Recipe-relative staging directory for one format's payload. Under
  ## ``.repro/`` so it never collides with the project's own ``build/``
  ## outputs and is ignored by the workspace scanner.
  ".repro/packaging/" & d.name & "/" & format

proc firstLine(s: string): string =
  let idx = s.find('\n')
  if idx < 0: s else: s[0 ..< idx]

proc heredoc(path, marker, body: string): seq[string] =
  ## A quoted-heredoc write of ``body`` to ``path`` — no shell expansion
  ## of the body (the ``'`` around the marker), so control/spec text is
  ## emitted verbatim.
  @["cat > " & path & " <<'" & marker & "'", body & marker]

proc systemdUnitBody(svc: ServiceUnit): string =
  ## Minimal systemd unit rendered from the abstract ``ServiceUnit``.
  var lines = @["[Unit]", "Description=" & svc.description, "",
    "[Service]", "ExecStart=" & svc.execStart, "",
    "[Install]", "WantedBy=" & svc.wantedBy, ""]
  lines.join("\n")

proc emitServiceUnits(d: Distribution): seq[string] =
  ## Write each service's systemd unit into the payload. System units go
  ## to ``usr/lib/systemd/system``; user units to ``usr/lib/systemd/user``.
  ## (The abstract list is authored once on the ``Distribution``; every
  ## format renders it — the launchd/rc.d/Windows renderings are M1.)
  for svc in d.services:
    let sub = (if svc.scope == ssSystem: "system" else: "user")
    let dir = "usr/lib/systemd/" & sub
    result.add("mkdir -p \"$root/" & dir & "\"")
    result.add(heredoc("\"$root/" & dir & "/" & svc.name & ".service\"",
      "REPRO_PKG_UNIT_EOF", systemdUnitBody(svc)))

proc serviceEnableScript(d: Distribution): string =
  ## The post-install body that enables each unit. Guarded with
  ## ``|| true`` so a non-systemd host (or a container without a running
  ## init) does not fail the install.
  var lines = @["#!/bin/sh", "set -e"]
  if d.services.len > 0:
    lines.add("systemctl daemon-reload || true")
    for svc in d.services:
      if svc.scope == ssSystem:
        lines.add("systemctl enable " & svc.name & ".service || true")
  lines.add("exit 0")
  lines.join("\n") & "\n"

proc attachTools(edge: BuildActionDef; d: Distribution;
                 extra: openArray[string]) =
  ## Fold the backend tool(s) — plus ``patchelf`` when the §5 vendored
  ## closure is non-empty and needs an RPATH rewrite — into the edge's
  ## tool-identity refs.
  var refs = @extra
  when not defined(macosx):
    if d.runtime.vendoredLibs.len > 0:
      refs.add("patchelf")
  appendRegisteredActionToolIdentityRefs(edge.id, refs)

# ---------------------------------------------------------------------------
# tarball — relocatable, wrapper-baked .tar.gz
# ---------------------------------------------------------------------------

proc tarball*(d: Distribution; output: string; actionId = ""):
    BuildActionDef {.discardable.} =
  ## Produce ``output`` (``<name>-<ver>-<os>-<arch>.tar.gz``): the shared
  ## §5 payload, gzip-tarred. Relocatable because the generated wrappers
  ## resolve the real binary relative to their own location.
  let root = stagingRoot(d, "tar")
  var s = @["set -eu", "rm -rf " & shq(root)]
  s.add(renderPayloadStaging(d, shq(root)))
  s.add("mkdir -p " & shq(output.parentDir))
  s.add("tar -czf " & shq(output) & " -C \"$root\" .")
  let id = (if actionId.len > 0: actionId else: "package-tarball-" & d.name)
  result = shell(command = s.join("\n"), actionId = id,
    extraInputs = payloadInputs(d), extraOutputs = @[output])
  attachTools(result, d, ["tar"])

# ---------------------------------------------------------------------------
# deb — Debian package via dpkg-deb --build
# ---------------------------------------------------------------------------

proc controlBody*(d: Distribution): string =
  ## The Debian ``DEBIAN/control`` text for ``d``. Exported so recipes /
  ## tests can inspect the generated metadata without running dpkg-deb.
  var lines = @[
    "Package: " & d.name,
    "Version: " & d.version,
    "Architecture: " & debArch(d.arch),
    "Maintainer: " & d.metadata.maintainer,
    "Section: " & d.metadata.section,
    "Priority: " & d.metadata.priority]
  if d.metadata.homepage.len > 0:
    lines.add("Homepage: " & d.metadata.homepage)
  # Description: first line is the synopsis; dpkg requires it non-empty.
  lines.add("Description: " & firstLine(d.metadata.description))
  lines.join("\n") & "\n"

proc deb*(d: Distribution; output: string; actionId = ""):
    BuildActionDef {.discardable.} =
  ## Produce ``output`` (``<name>_<ver>_<debArch>.deb``): the shared §5
  ## payload plus a ``DEBIAN/control`` and, when services are declared, a
  ## ``postinst`` that enables the systemd units.
  ##
  ## ``dpkg-deb --build --root-owner-group`` stamps root:root ownership
  ## without fakeroot, keeping the edge hermetic and reproducible.
  let root = stagingRoot(d, "deb")
  var s = @["set -eu", "rm -rf " & shq(root)]
  s.add(renderPayloadStaging(d, shq(root)))
  s.add(emitServiceUnits(d).join("\n"))
  s.add("mkdir -p \"$root/DEBIAN\"")
  s.add(heredoc("\"$root/DEBIAN/control\"", "REPRO_PKG_CTRL_EOF",
    controlBody(d)).join("\n"))
  if d.services.len > 0:
    s.add(heredoc("\"$root/DEBIAN/postinst\"", "REPRO_PKG_POST_EOF",
      serviceEnableScript(d)).join("\n"))
    s.add("chmod 0755 \"$root/DEBIAN/postinst\"")
  s.add("mkdir -p " & shq(output.parentDir))
  s.add("dpkg-deb --build --root-owner-group \"$root\" " & shq(output))
  let id = (if actionId.len > 0: actionId else: "package-deb-" & d.name)
  result = shell(command = s.join("\n"), actionId = id,
    extraInputs = payloadInputs(d), extraOutputs = @[output])
  attachTools(result, d, ["dpkg-deb"])

# ---------------------------------------------------------------------------
# rpm — RPM package via rpmbuild -bb
# ---------------------------------------------------------------------------

proc specBody*(d: Distribution): string =
  ## A self-contained binary ``.spec``. Exported so recipes / tests can
  ## inspect the generated spec without running rpmbuild. ``%install`` copies the
  ## pre-staged §5 payload (passed as ``%{payloadsrc}``) into the
  ## buildroot; post-install processing is disabled
  ## (``__os_install_post %{nil}``) so the edge needs no strip/debuginfo
  ## toolchain and stays portable across build hosts.
  var lines = @[
    "%global debug_package %{nil}",
    "%global __os_install_post %{nil}",
    "Name: " & d.name,
    "Version: " & d.version,
    "Release: 1",
    "Summary: " & firstLine(d.metadata.description),
    "License: " & d.metadata.license,
    "BuildArch: " & rpmArch(d.arch)]
  if d.metadata.homepage.len > 0:
    lines.add("URL: " & d.metadata.homepage)
  lines.add("")
  lines.add("%description")
  lines.add(d.metadata.description)
  lines.add("")
  lines.add("%install")
  lines.add("rm -rf \"$RPM_BUILD_ROOT\"")
  lines.add("mkdir -p \"$RPM_BUILD_ROOT\"")
  lines.add("cp -a %{payloadsrc}/. \"$RPM_BUILD_ROOT/\"")
  lines.add("")
  lines.add("%files")
  for p in installedPaths(d):
    lines.add(p)
  lines.add("")
  if d.services.len > 0:
    lines.add("%post")
    lines.add("systemctl daemon-reload || true")
    for svc in d.services:
      if svc.scope == ssSystem:
        lines.add("systemctl enable " & svc.name & ".service || true")
    lines.add("")
  lines.join("\n") & "\n"

proc rpm*(d: Distribution; output: string; actionId = ""):
    BuildActionDef {.discardable.} =
  ## Produce ``output`` (``<name>-<ver>-1.<rpmArch>.rpm``): the shared §5
  ## payload, packaged by ``rpmbuild -bb`` from a generated spec.
  let payload = stagingRoot(d, "rpm-payload")
  let topdir = stagingRoot(d, "rpmbuild")
  let specPath = "\"$PWD/" & topdir & "/SPECS/" & d.name & ".spec\""
  var s = @["set -eu", "rm -rf " & shq(payload) & " " & shq(topdir)]
  s.add(renderPayloadStaging(d, shq(payload)))
  s.add("mkdir -p " & shq(topdir & "/SPECS") & " " &
    shq(topdir & "/BUILD") & " " & shq(topdir & "/RPMS"))
  s.add(heredoc(specPath, "REPRO_PKG_SPEC_EOF", specBody(d)).join("\n"))
  s.add("rpmbuild -bb" &
    " --define \"_topdir $PWD/" & topdir & "\"" &
    " --define \"payloadsrc $PWD/" & payload & "\"" &
    " " & specPath)
  s.add("mkdir -p " & shq(output.parentDir))
  s.add("cp \"$PWD/" & topdir & "/RPMS/" & rpmArch(d.arch) & "/" &
    d.name & "-" & d.version & "-1." & rpmArch(d.arch) & ".rpm\" " & shq(output))
  let id = (if actionId.len > 0: actionId else: "package-rpm-" & d.name)
  result = shell(command = s.join("\n"), actionId = id,
    extraInputs = payloadInputs(d), extraOutputs = @[output])
  attachTools(result, d, ["rpmbuild"])
