#!/usr/bin/env python3
"""
generate-de-k1-catalogs.py - DE-K1 catalog generator.

Run INSIDE the repro-ubuntu WSL distro (it needs apt-get / dpkg-deb to
download + introspect .deb archives). Produces 30 catalog JSON files
under recipes/catalog/linux/ describing the DE-K1 closure.

Usage:
    cd /tmp/dek1-debs
    python3 /mnt/d/metacraft/reprobuild/recipes/reproos-mvp-config/scripts/generate-de-k1-catalogs.py \\
        --out /mnt/d/metacraft/reprobuild/recipes/catalog/linux \\
        --work /tmp/dek1-debs

The generator:

  1. For each catalog grouping, calls `apt-get download` for the
     declared .debs into $WORK/.
  2. Computes sha256 + size for each .deb.
  3. Runs `dpkg-deb -c` to enumerate paths.
  4. Auto-selects "expected_files":
     * binaries: usr/bin/* + usr/sbin/* + usr/libexec/* (regular
       files, executable bit) — first 2 entries per .deb to keep the
       catalog focused.
     * shared_library: the highest-versioned lib*.so.N.M.K under
       usr/lib/x86_64-linux-gnu/ (and its SONAME link's basename).
       One headline lib per .deb.
  5. Writes a JSON file with the same shape as
     recipes/catalog/linux/gdm.json (the multi-deb-per-catalog
     precedent).

The expected_files lists are intentionally minimal — the DE-K1 builder's
special "full-tree extract for data debs" pattern (mirroring DE-G1's
adwaita / gsettings handling) covers the bulk-content debs.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

# ----------------------------------------------------------------------------
# Catalog groupings. ORDER MATTERS for registry.json byte-stability.
#
# Schema for each entry:
#   "name": catalog file basename (no .json)
#   "version": version of the lead .deb (used to fingerprint the store dir)
#   "primary_pkg": the .deb whose version the catalog tracks
#   "pkgs": list of .deb package names
#   "dependency_closure": list of shared catalog names (other catalogs)
#   "rationale": human-readable why this grouping
#   "full_extract_pkgs": list of pkgs whose entire tree should be planted
#     (the builder treats these specially)
#   "pocket": "main" | "universe"
# ----------------------------------------------------------------------------

# Common dependencies from DE0-G / DE-H1 / DE-G1 catalogs.
DE0G_DEPS = ["libwayland", "libxkbcommon", "libdrm", "mesa"]
DEH1G1_SHARED = ["libsystemd", "libpipewire", "libxcb1", "libxcb-extras",
                 "libxkbfile", "libxkbcommon-x11", "libice", "libsm",
                 "libsoup2.4", "libpolkit", "libnss", "libwacom",
                 "libgudev"]

GROUPINGS = [
    {
        "name": "sddm",
        "primary_pkg": "sddm",
        "pkgs": ["sddm"],
        "dependency_closure": DEH1G1_SHARED + ["qt5-base", "qt5-declarative"],
        "rationale": "SDDM 0.19.0 jammy. Wayland-mode display manager. Ships sddm sbin + sddm-greeter binary + 3 PAM stacks (/etc/pam.d/sddm{,-autologin,-greeter}) + lib/systemd/system/sddm.service + dbus system.d conf. Single-deb catalog, parallel to DE-G1's gdm.json but with the daemon binary in /usr/bin not /usr/sbin.",
        "pocket": "universe",
    },
    {
        "name": "kwin",
        "primary_pkg": "kwin-common",
        "pkgs": ["kwin-common", "kwin-wayland"],
        "dependency_closure": DEH1G1_SHARED + ["plasma-framework", "kf5-core", "kf5-gui", "kf5-frameworks", "qt5-base", "qt5-wayland", "kwin-libs"],
        "rationale": "KWin 5.24.7 jammy. kwin-common ships /usr/bin/kwin_wayland + /usr/bin/kwin_x11 + the kwin plugin tree under usr/lib/x86_64-linux-gnu/qt5/plugins/kwin/. kwin-wayland is the Wayland-specific session helper. The kwin-libs catalog ships the dedicated effect/decoration helper libs.",
        "pocket": "universe",
    },
    {
        "name": "kwin-libs",
        "primary_pkg": "libkwineffects13",
        "pkgs": ["libkwineffects13", "libkwinglutils13", "libkwinxrenderutils13", "libkdecorations2-5v5", "libkdecorations2private9"],
        "dependency_closure": ["qt5-base"],
        "rationale": "KWin effect / decoration helper libs. libkwineffects.so.13 is the effects API; libkwinglutils.so.13 wraps the GL helper; libkwinxrenderutils.so.13 is the legacy X-Render helper. libkdecorations2 is the window-decoration API (both public + private companion). Jammy's KWin 5.24 ABI uses sover 13 (not 15) for the effects/glutils libs and sover 9 (not 8) for the decorations private lib.",
        "pocket": "universe",
    },
    {
        "name": "plasma-workspace",
        "primary_pkg": "plasma-workspace",
        "pkgs": ["plasma-workspace", "plasma-workspace-wayland", "libplasma-geolocation-interface5", "libtaskmanager6", "libnotificationmanager1", "libkworkspace5-5", "sddm-theme-breeze"],
        "dependency_closure": ["kf5-core", "kf5-gui", "kf5-frameworks", "kf5-declarative", "kio", "kded", "plasma-framework", "kactivities", "qt5-base", "qt5-declarative", "qt5-wayland", "qml-modules", "libksysguard"],
        "rationale": "Plasma workspace - the largest .deb in DE-K1 (11.8 MB). Ships /usr/bin/plasmashell + /usr/bin/krunner + /usr/bin/kcminit + /usr/bin/ksmserver + /usr/bin/startplasma-wayland + 23 helpers under usr/libexec/. The -wayland deb ships the Wayland session entry. The four lib*.debs (plasma-geolocation-interface, taskmanager, notificationmanager, kworkspace5) ship runtime-only helper libs hard-deped by plasmashell.",
        "pocket": "universe",
        "full_extract_pkgs": ["sddm-theme-breeze"],
    },
    {
        "name": "plasma-desktop",
        "primary_pkg": "plasma-desktop",
        "pkgs": ["plasma-desktop", "plasma-desktop-data"],
        "dependency_closure": ["plasma-workspace", "kf5-core", "kf5-gui", "kio"],
        "rationale": "Plasma desktop session glue + data. The -data deb ships /usr/share/plasma/desktoptheme/, /usr/share/wallpapers/, the l10n files.",
        "pocket": "universe",
        "full_extract_pkgs": ["plasma-desktop-data"],
    },
    {
        "name": "plasma-framework",
        "primary_pkg": "plasma-framework",
        "pkgs": ["plasma-framework", "libkf5plasma5", "libkf5plasmaquick5"],
        "dependency_closure": ["kf5-core", "kf5-gui", "kf5-frameworks", "kf5-declarative", "qt5-base", "qt5-declarative"],
        "rationale": "KF5 Plasma framework + its QtQuick bridge. libkf5plasma5.so.5 is the C++ Plasma API; libkf5plasmaquick5.so.5 exposes it to QML. plasma-framework ships shared assets /usr/share/plasma/.",
        "pocket": "universe",
    },
    {
        "name": "plasma-integration",
        "primary_pkg": "plasma-integration",
        "pkgs": ["plasma-integration", "polkit-kde-agent-1"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "qt5-base"],
        "rationale": "Qt 5 platform-theme plugin for Plasma + the Polkit auth agent (kde-authentication-agent-1 binary).",
        "pocket": "universe",
    },
    {
        "name": "kactivities",
        "primary_pkg": "kactivitymanagerd",
        "pkgs": ["kactivitymanagerd", "libkf5activities5"],
        "dependency_closure": ["kf5-core", "kf5-frameworks"],
        "rationale": "KDE Activities daemon + KF5 activities client lib. Plasma 5 requires kactivitymanagerd running on the session bus for desktop activity switching.",
        "pocket": "universe",
    },
    {
        "name": "breeze",
        "primary_pkg": "breeze",
        "pkgs": ["breeze", "breeze-cursor-theme"],
        "dependency_closure": ["kf5-core", "kf5-gui", "qt5-base"],
        "rationale": "Breeze widget style + window decoration theme + cursor theme. Largest single .deb in DE-K1 by extracted size (6.87 MB compressed; icons + decoration assets).",
        "pocket": "universe",
        "full_extract_pkgs": ["breeze-cursor-theme"],
    },
    {
        "name": "kf5-core",
        "primary_pkg": "libkf5coreaddons5",
        "pkgs": ["libkf5coreaddons5", "libkf5coreaddons-data",
                 "libkf5configcore5", "libkf5configgui5", "libkf5configwidgets5",
                 "libkf5configwidgets-data", "libkf5config-data",
                 "libkf5dbusaddons5", "libkf5dbusaddons-data",
                 "libkf5authcore5", "libkf5auth-data",
                 "libkf5crash5", "libkf5archive5",
                 "libkf5codecs5", "libkf5codecs-data"],
        "dependency_closure": ["qt5-base"],
        "rationale": "KF5 core frameworks aggregated (KAuth + KCodecs + KConfig + KCoreAddons + KCrash + KDBusAddons + KArchive). 15 .debs in one catalog to stay under the 30-catalog cap.",
        "pocket": "universe",
    },
    {
        "name": "kf5-gui",
        "primary_pkg": "libkf5widgetsaddons5",
        "pkgs": ["libkf5guiaddons5", "libkf5guiaddons-bin", "libkf5guiaddons-data",
                 "libkf5widgetsaddons5", "libkf5widgetsaddons-data",
                 "libkf5itemviews5", "libkf5jobwidgets5",
                 "libkf5iconthemes5", "libkf5iconthemes-data",
                 "libkf5completion5", "libkf5completion-data",
                 "libkf5i18n5", "libkf5i18n-data"],
        "dependency_closure": ["kf5-core", "qt5-base"],
        "rationale": "KF5 GUI helper frameworks aggregated (KGuiAddons + KWidgetsAddons + KItemViews + KJobWidgets + KIconThemes + KCompletion + KI18n). 13 .debs in one catalog. libkf5i18n-data is the second-largest .deb in DE-K1 (1.21 MB compressed; l10n catalogs for 60+ locales).",
        "pocket": "universe",
    },
    {
        "name": "kf5-frameworks",
        "primary_pkg": "libkf5windowsystem5",
        "pkgs": ["libkf5windowsystem5", "libkf5windowsystem-data",
                 "libkf5globalaccel5", "libkf5globalaccel-bin", "libkf5globalaccel-data", "libkf5globalaccelprivate5",
                 "libkf5xmlgui5", "libkf5xmlgui-data", "libkf5xmlgui-bin",
                 "libkf5notifications5", "libkf5notifications-data",
                 "libkf5notifyconfig5", "libkf5notifyconfig-data",
                 "libkf5service5", "libkf5service-bin", "libkf5service-data",
                 "libkf5kcmutils5",
                 "libkf5package5", "libkf5package-data",
                 "libkf5sonnetcore5", "libkf5sonnetui5", "libkf5sonnet5-data"],
        "dependency_closure": ["kf5-core", "kf5-gui", "qt5-base"],
        "rationale": "KF5 desktop-tier frameworks aggregated (KWindowSystem + KGlobalAccel + KXmlGui + KNotifications + KNotifyConfig + KService + KCMUtils + KPackage + Sonnet). 22 .debs in one catalog.",
        "pocket": "universe",
    },
    {
        "name": "kf5-declarative",
        "primary_pkg": "libkf5declarative5",
        "pkgs": ["libkf5declarative5", "libkf5quickaddons5"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "qt5-base", "qt5-declarative"],
        "rationale": "KF5 QML bridge (KDeclarative + KQuickAddons). Required by plasmashell + krunner for their QML UI.",
        "pocket": "universe",
    },
    {
        "name": "kf5-runner",
        "primary_pkg": "libkf5runner5",
        "pkgs": ["libkf5runner5"],
        "dependency_closure": ["kf5-core", "kf5-frameworks"],
        "rationale": "KF5 Runner API (krunner search-result plugin interface).",
        "pocket": "universe",
    },
    {
        "name": "kf5-newstuff",
        "primary_pkg": "libkf5newstuff5",
        "pkgs": ["libkf5newstuff5", "libkf5newstuffcore5", "libkf5newstuff-data"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "kio"],
        "rationale": "KF5 KNewStuff (the 'Get Hot New Stuff' plugin system). Hard-deped by plasma-workspace's wallpaper picker.",
        "pocket": "universe",
    },
    {
        "name": "kio",
        "primary_pkg": "kio",
        "pkgs": ["kio",
                 "libkf5kiocore5", "libkf5kiogui5", "libkf5kiowidgets5",
                 "libkf5kiofilewidgets5", "libkf5kiontlm5",
                 "libkf5bookmarks5", "libkf5parts5"],
        "dependency_closure": ["kf5-core", "kf5-gui", "kf5-frameworks", "qt5-base"],
        "rationale": "KIO virtual-filesystem framework + 5 client libs + KBookmarks + KParts. plasmashell hard-deps libKF5KIOCore for its 'open file' dialog.",
        "pocket": "universe",
    },
    {
        "name": "kded",
        "primary_pkg": "kded5",
        "pkgs": ["kded5", "kpackagetool5", "kde-cli-tools"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "kio"],
        "rationale": "KDED5 (desktop-bus daemon used by kactivitymanagerd + plasmashell + KIO scheduler) + kpackagetool5 (CLI for KPackage) + kde-cli-tools (kcmshell5 + kdesu5 + kioclient5 + kstart5).",
        "pocket": "universe",
    },
    {
        "name": "kdelibs4support",
        "primary_pkg": "libkf5kdelibs4support5",
        "pkgs": ["libkf5kdelibs4support5"],
        "dependency_closure": ["kf5-core", "kf5-gui", "kf5-frameworks"],
        "rationale": "KDELibs 4 -> KF5 transition shim. Hard-deped by plasma-desktop for legacy KGlobal::config() / KConfigGroup global access.",
        "pocket": "universe",
    },
    {
        "name": "kf5-extras",
        "primary_pkg": "libkf5solid5",
        "pkgs": ["libkf5solid5", "libkf5solid5-data", "libkf5baloo5", "libkaccounts2"],
        "dependency_closure": ["kf5-core", "qt5-base"],
        "rationale": "KF5 Solid (hardware abstraction) + KBaloo (file indexer client lib) + KAccounts (account integration framework client lib). No daemons planted.",
        "pocket": "universe",
    },
    {
        "name": "qt5-base",
        "primary_pkg": "libqt5core5a",
        "pkgs": ["libqt5core5a", "libqt5gui5", "libqt5widgets5",
                 "libqt5network5", "libqt5dbus5", "libqt5xml5",
                 "libqt5sql5", "libqt5concurrent5", "libqt5x11extras5",
                 "libqt5opengl5"],
        "dependency_closure": DE0G_DEPS + DEH1G1_SHARED,
        "rationale": "Qt 5.15.3 base libraries from qtbase-opensource-src + qtx11extras. 10 .debs aggregated. libqt5gui5 (3.72 MB) is the largest; ships the QPA platform plugin loader + xcb/wayland/minimal/offscreen backends.",
        "pocket": "universe",
    },
    {
        "name": "qt5-declarative",
        "primary_pkg": "libqt5qml5",
        "pkgs": ["libqt5qml5", "libqt5quick5", "libqt5quickwidgets5",
                 "libqt5quicktemplates2-5", "libqt5quickparticles5",
                 "libqt5quickshapes5", "libqt5quicktest5"],
        "dependency_closure": ["qt5-base"],
        "rationale": "Qt 5 Declarative (QML + Quick) - the runtime of every Plasma UI. plasmashell + krunner + plasma-discover are all QML apps.",
        "pocket": "universe",
    },
    {
        "name": "qt5-wayland",
        "primary_pkg": "qtwayland5",
        "pkgs": ["qtwayland5", "libqt5waylandclient5", "libqt5waylandcompositor5"],
        "dependency_closure": ["qt5-base", "libwayland", "libxkbcommon"],
        "rationale": "Qt 5 Wayland integration. libQt5WaylandClient.so.5 is the wl_compositor-side Qt platform plugin client; libQt5WaylandCompositor.so.5 is the compositor-side API used by kwin_wayland.",
        "pocket": "universe",
    },
    {
        "name": "qt5-svg",
        "primary_pkg": "libqt5svg5",
        "pkgs": ["libqt5svg5"],
        "dependency_closure": ["qt5-base"],
        "rationale": "Qt 5 SVG renderer. Loaded by KIconThemes + by Plasma's QML SVG decorations.",
        "pocket": "universe",
    },
    {
        "name": "qml-modules",
        "primary_pkg": "qml-module-qtquick2",
        "pkgs": ["qml-module-qtquick2", "qml-module-qtquick-window2",
                 "qml-module-qtquick-layouts",
                 "qml-module-qtquick-controls", "qml-module-qtquick-controls2",
                 "qml-module-qtquick-templates2", "qml-module-qtquick-dialogs",
                 "qml-module-qt-labs-folderlistmodel",
                 "qml-module-qt-labs-settings",
                 "qml-module-org-kde-kirigami2",
                 "qml-module-org-kde-kquickcontrols",
                 "qml-module-org-kde-kquickcontrolsaddons",
                 "qml-module-org-kde-kwindowsystem",
                 "qml-module-org-kde-kcoreaddons",
                 "qml-module-org-kde-solid",
                 "qml-module-org-kde-draganddrop"],
        "dependency_closure": ["qt5-base", "qt5-declarative", "kf5-core", "kf5-frameworks", "kf5-declarative"],
        "rationale": "All QML modules loaded by plasmashell / krunner / kwin's QML scripts. 16 .debs aggregated. Each .deb ships a qml/<module>/qmldir + lib*.so plugin. Aggregator pattern parallels DE-G1's gsettings/adwaita data debs.",
        "pocket": "universe",
        "full_extract_pkgs": ["qml-module-qtquick2", "qml-module-qtquick-window2",
                              "qml-module-qtquick-layouts",
                              "qml-module-qtquick-controls", "qml-module-qtquick-controls2",
                              "qml-module-qtquick-templates2", "qml-module-qtquick-dialogs",
                              "qml-module-qt-labs-folderlistmodel",
                              "qml-module-qt-labs-settings",
                              "qml-module-org-kde-kirigami2",
                              "qml-module-org-kde-kquickcontrols",
                              "qml-module-org-kde-kquickcontrolsaddons",
                              "qml-module-org-kde-kwindowsystem",
                              "qml-module-org-kde-kcoreaddons",
                              "qml-module-org-kde-solid",
                              "qml-module-org-kde-draganddrop"],
    },
    {
        "name": "phonon",
        "primary_pkg": "phonon4qt5",
        "pkgs": ["phonon4qt5", "libphonon4qt5-4"],
        "dependency_closure": ["qt5-base"],
        "rationale": "Phonon 4 (Qt 5 binding). Plasma's notification daemon + media controls. The phonon backend (gstreamer/vlc) is NOT planted; phonon falls back to its null backend at runtime - notifications work silently.",
        "pocket": "universe",
    },
    {
        "name": "xdg-desktop-portal-kde",
        "primary_pkg": "xdg-desktop-portal-kde",
        "pkgs": ["xdg-desktop-portal-kde"],
        "dependency_closure": ["qt5-base", "kf5-core", "kf5-frameworks", "kio", "libpipewire"],
        "rationale": "KDE backend for xdg-desktop-portal. Forwards file-chooser/screenshot/screencast requests to KWin + plasmashell.",
        "pocket": "universe",
    },
    {
        "name": "libkscreenlocker",
        "primary_pkg": "libkscreenlocker5",
        "pkgs": ["libkscreenlocker5"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "qt5-base"],
        "rationale": "KScreenLocker shared library. Loaded by plasma-workspace's screen-lock dispatch. The lock-screen UI binary kscreenlocker_greet is shipped under usr/libexec/.",
        "pocket": "universe",
    },
    {
        "name": "libksysguard",
        "primary_pkg": "libprocesscore9",
        "pkgs": ["libksgrd9", "libksignalplotter9", "libprocesscore9", "libprocessui9", "libkf5sysguard-bin"],
        "dependency_closure": ["kf5-core", "kf5-frameworks", "qt5-base"],
        "rationale": "KSysGuard libs (system monitor data sources, signal-plot widget, process tree). plasma-workspace's plasma-systemmonitor applet links them.",
        "pocket": "universe",
    },
    {
        "name": "libxcb-extras-kde",
        "primary_pkg": "libxcb-keysyms1",
        "pkgs": ["libxcb-keysyms1", "libxcb-record0", "libxcb-cursor0",
                 "libxcb-image0", "libxcb-icccm4", "libxcb-util1",
                 "libxcb-randr0", "libxcb-render0", "libxcb-render-util0",
                 "libxcb-shape0"],
        "dependency_closure": ["libxcb1"],
        "rationale": "XCB extras specifically required by kwin_x11 fallback path + Qt5 XCB QPA plugin. Distinct from DE-H1's libxcb-extras.json (different subset).",
        "pocket": "main",
    },
    {
        "name": "oxygen-sounds",
        "primary_pkg": "oxygen-sounds",
        "pkgs": ["oxygen-sounds", "libkuserfeedbackcore1", "libpackagekitqt5-1", "libpolkit-qt5-1-1"],
        "dependency_closure": ["qt5-base"],
        "rationale": "Plasma audio assets (Oxygen sound theme) + 3 small client libraries plasma-desktop hard-deps but are too small to warrant their own catalogs.",
        "pocket": "universe",
        "full_extract_pkgs": ["oxygen-sounds"],
    },
]

SNAPSHOT = "ubuntu/jammy/20260615T000000Z"
DISTRO = "linux-graphics"
PKG_SRC = "ubuntu-jammy"


def run(cmd, capture=True, **kwargs):
    if isinstance(cmd, str):
        cmd_str = cmd
    else:
        cmd_str = " ".join(shlex.quote(c) for c in cmd)
    if capture:
        return subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    return subprocess.run(cmd, **kwargs)


def apt_cache_show(pkg):
    """Return the first stanza dict (Package + Version + Filename + Size +
    SHA256). Falls back across multiple available versions; we want the
    newest/security-pocket build."""
    r = run(["apt-cache", "show", pkg])
    if r.returncode != 0 or not r.stdout.strip():
        return None
    stanza = {}
    for line in r.stdout.splitlines():
        if not line.strip():
            if stanza.get("Package") and stanza.get("Version"):
                # First complete stanza.
                return stanza
            stanza = {}
            continue
        m = re.match(r"^([A-Za-z0-9-]+):\s+(.*)$", line)
        if m:
            stanza.setdefault(m.group(1), m.group(2))
    if stanza.get("Package") and stanza.get("Version"):
        return stanza
    return None


def download_deb(pkg, work_dir):
    """apt-get download into work_dir/; return path to the .deb."""
    work_dir = Path(work_dir)
    # apt-get download dumps the .deb into the cwd as <pkg>_<version>_<arch>.deb.
    r = subprocess.run(
        ["apt-get", "download", pkg],
        cwd=str(work_dir),
        capture_output=True, text=True
    )
    if r.returncode != 0:
        sys.stderr.write(f"apt-get download {pkg} FAILED:\n{r.stderr}\n")
        return None
    # Find the newest matching .deb.
    candidates = sorted(work_dir.glob(f"{pkg}_*.deb"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        sys.stderr.write(f"apt-get download {pkg}: no .deb found in {work_dir}\n")
        return None
    return candidates[-1]


def file_sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def dpkg_deb_contents(deb_path):
    """Run dpkg-deb -c and return list of (perm, path, link_target)."""
    r = run(["dpkg-deb", "-c", str(deb_path)])
    out = []
    if r.returncode != 0:
        return out
    for line in r.stdout.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        perm, _owner, _size, _date, _time, rest = parts
        # rest may have "-> target" for symlinks.
        if " -> " in rest:
            path, link = rest.split(" -> ", 1)
        else:
            path, link = rest, None
        # Strip leading "./".
        if path.startswith("./"):
            path = path[2:]
        out.append((perm, path, link))
    return out


SO_REAL_RE = re.compile(r"^(.+/lib[^/]+)\.so\.(\d+(?:\.\d+)*(?:\.\d+)?)$")
SO_LINK_RE = re.compile(r"^(.+/lib[^/]+)\.so\.(\d+)$")  # SONAME link form

# Binaries we ALWAYS want pinned when present (across many .debs). This
# avoids the alphabetic-first-2 heuristic picking unimportant tools like
# `gmenudbusmenuproxy` over `plasmashell` / `kwin_wayland` / `startplasma-wayland`.
PRIORITY_BIN_NAMES = {
    "plasmashell", "krunner", "kcminit", "ksmserver", "startplasma-wayland",
    "startplasma-x11", "kwin_wayland", "kwin_x11", "kwin_wayland_wrapper",
    "kded5", "kpackagetool5", "kcmshell5", "kde-cli-tools",
    "sddm", "sddm-greeter",
    "kactivitymanagerd",
    "polkit-kde-authentication-agent-1",
}


def select_expected_files(contents, pkg_name):
    """Auto-select expected_files for a .deb's contents.

    Strategy:
      - Binaries:
          * Priority pass: any name in PRIORITY_BIN_NAMES regardless of dir.
          * Fallback pass: alphabetic-first 2 usr/bin/* | usr/sbin/* |
            usr/libexec/* with exec bit.
      - Shared library: walk the symlink chain. For each lib*.so.N
        symlink whose target is a regular versioned file, emit
          { path: <real_versioned_file>, soname_link: <symlink_path> }.
        Pick the highest-sover symlink (so libtaskmanager.so.6 wins over
        libfoo.so.0 inside the same .deb).
    """
    expected = []

    # Map of real path -> bin/exec.
    regular_files = {}
    # Map of symlink path -> target (basename or relative).
    sym_links = {}
    for perm, path, link in contents:
        if path.endswith("/"):
            continue
        if perm.startswith("l"):
            sym_links[path] = link
        elif perm.startswith("-"):
            regular_files[path] = perm

    # ----------------------------- shared library -----------------------------
    # We look for symlinks of the form .../libFOO.so.<sover> whose target
    # resolves to a real file under the same directory.
    lib_candidates = []  # (sover_int, symlink_path, real_path)
    for sp, tgt in sym_links.items():
        m = SO_LINK_RE.match(sp)
        if not m:
            continue
        # tgt may be a basename ("libtaskmanager.so.5.24.7") or relative path.
        dir_of_sp = os.path.dirname(sp)
        tgt_basename = os.path.basename(tgt)
        real_path = f"{dir_of_sp}/{tgt_basename}"
        if real_path in regular_files:
            try:
                sover = int(m.group(2))
            except ValueError:
                sover = 0
            lib_candidates.append((sover, sp, real_path))

    if lib_candidates:
        # Highest sover wins (libtaskmanager.so.6 over libfoo.so.0).
        lib_candidates.sort()
        sover, soname_link, real_path = lib_candidates[-1]
        expected.append({
            "kind": "shared_library",
            "path": real_path,
            "soname_link": soname_link,
        })
    else:
        # Fallback: scan for unique .so.N regular files (no symlink) — e.g.
        # data debs that ship only a versioned library directly.
        for path, perm in regular_files.items():
            if not path.startswith("usr/lib/x86_64-linux-gnu/"):
                continue
            m = SO_REAL_RE.match(path)
            if m and "x" in perm[1:10]:
                # Derive an implicit soname (chop to first .so.N).
                parts = path.split(".so.")
                if len(parts) == 2:
                    sover = parts[1].split(".")[0]
                    expected.append({
                        "kind": "shared_library",
                        "path": path,
                        "soname_link": f"{parts[0]}.so.{sover}",
                    })
                    break

    # ----------------------------- binaries -----------------------------
    bins_priority = []
    bins_alpha = []
    for path, perm in regular_files.items():
        if not (path.startswith("usr/bin/") or path.startswith("usr/sbin/") or
                path.startswith("usr/libexec/") or path.startswith("bin/") or
                path.startswith("sbin/")):
            continue
        if "x" not in perm[1:10]:
            continue
        bn = os.path.basename(path)
        if bn in PRIORITY_BIN_NAMES:
            bins_priority.append(path)
        else:
            bins_alpha.append(path)

    bins_priority.sort()
    bins_alpha.sort()
    seen_bn = set()
    out_bins = []
    # Up to 4 priority binaries (plasmashell + krunner + kcminit + startplasma-x11),
    # then up to 1 alpha fallback for catalogs with no priority hits.
    pri_taken = 0
    for b in bins_priority:
        bn = os.path.basename(b)
        if bn in seen_bn:
            continue
        seen_bn.add(bn)
        out_bins.append(b)
        pri_taken += 1
        if pri_taken >= 4:
            break
    if not out_bins:
        for b in bins_alpha[:2]:
            bn = os.path.basename(b)
            if bn in seen_bn:
                continue
            seen_bn.add(bn)
            out_bins.append(b)

    for b in out_bins:
        expected.append({"kind": "binary", "path": b})

    return expected


def select_data_path(contents):
    """For full-extract data .debs: return one representative file path so
    expected_files isn't empty (the builder asserts the file exists post-
    extract). Pick the alphabetically-first regular file under usr/share/."""
    for perm, path, link in contents:
        if perm.startswith("-") and path.startswith("usr/share/") and not path.endswith("/"):
            return path
    # Fall back: any regular file.
    for perm, path, link in contents:
        if perm.startswith("-") and not path.endswith("/"):
            return path
    return None


def build_catalog(group, work_dir):
    name = group["name"]
    pkgs = group["pkgs"]
    primary = group["primary_pkg"]
    rationale = group["rationale"]
    pocket = group["pocket"]
    closure_names = group["dependency_closure"]
    full_extract = set(group.get("full_extract_pkgs", []))

    print(f"== {name} ({len(pkgs)} .debs) ==", file=sys.stderr)

    primary_stanza = apt_cache_show(primary)
    if not primary_stanza:
        raise SystemExit(f"{name}: primary pkg '{primary}' not in apt cache")
    primary_version = primary_stanza["Version"]

    payload_files = []

    for pkg in pkgs:
        stanza = apt_cache_show(pkg)
        if not stanza:
            sys.stderr.write(f"  WARN: {pkg} not in apt cache; skipping\n")
            continue
        deb_path = download_deb(pkg, work_dir)
        if not deb_path:
            sys.stderr.write(f"  WARN: {pkg} download failed; skipping\n")
            continue

        sha = file_sha256(deb_path)
        size = deb_path.stat().st_size
        # Sanity: cross-check against apt's SHA256.
        if stanza.get("SHA256") and stanza["SHA256"] != sha:
            sys.stderr.write(f"  WARN: {pkg} sha mismatch; apt={stanza['SHA256']} got={sha}\n")

        contents = dpkg_deb_contents(deb_path)
        if pkg in full_extract:
            data_path = select_data_path(contents)
            expected = [{"kind": "data", "path": data_path}] if data_path else []
        else:
            expected = select_expected_files(contents, pkg)
            if not expected:
                # Fall back: tag one data file for catalog non-emptiness.
                dp = select_data_path(contents)
                if dp:
                    expected = [{"kind": "data", "path": dp}]

        # deb_url: rewrite Filename relative to archive.ubuntu.com.
        filename = stanza.get("Filename", "")
        if filename.startswith("pool/"):
            deb_url = f"http://archive.ubuntu.com/ubuntu/{filename}"
        else:
            deb_url = filename
        payload_files.append({
            "deb_pkg": pkg,
            "deb_url": deb_url,
            "deb_sha256": sha,
            "deb_size_bytes": size,
            "expected_files": expected,
        })
        print(f"  {pkg} {stanza['Version']} -> {len(expected)} expected_files", file=sys.stderr)

    dep_closure = [
        {"distro": DISTRO, "name": d, "snapshot": SNAPSHOT}
        for d in closure_names
    ]

    catalog = {
        "format_version": 1,
        "runtime": "linux",
        "package": {
            "distro": DISTRO,
            "name": name,
            "snapshot": SNAPSHOT,
            "version": primary_version,
        },
        "package_source": PKG_SRC,
        "payload_files": payload_files,
        "dependency_closure": dep_closure,
        "linux_version_banner": "",
        "provisioning_methods": [
            {"kind": "ubuntu-jammy-archive", "pocket": pocket}
        ],
        "signed_envelope": None,
        "version_pin_rationale": rationale,
    }
    return catalog


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="Output dir for *.json")
    ap.add_argument("--work", required=True, help="Scratch dir for downloads")
    ap.add_argument("--only", default="", help="Comma-separated catalog names to generate (default: all)")
    args = ap.parse_args()

    out_dir = Path(args.out)
    work_dir = Path(args.work)
    out_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    selected = set(s.strip() for s in args.only.split(",") if s.strip()) if args.only else None
    for group in GROUPINGS:
        if selected and group["name"] not in selected:
            continue
        cat = build_catalog(group, work_dir)
        out_path = out_dir / f"{group['name']}.json"
        with open(out_path, "w") as f:
            json.dump(cat, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
