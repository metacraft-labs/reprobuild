#!/usr/bin/env python3
"""Generate the 33 DE-G1 catalog JSON files.

DE-G1 follows the same schema as DE-H1 (recipes/catalog/linux/SCHEMA.md).
This generator emits one catalog per GNOME stack tier, with hand-curated
dependency_closure[] entries lifted from `ldd` audit + apt-cache depends.

Usage:
  python3 scripts/generate_deg1_catalogs.py <output_dir>

The script is hermetic — every deb URL, sha256, size, and expected_files[]
entry is hardcoded from the empirical audit in /root/deg1-work on
repro-ubuntu (jammy 22.04.5 LTS) on 2026-06-15.
"""

import json
import os
import sys
import urllib.parse

# DE0-G snapshot (existing).
DE0_G = "ubuntu/jammy/20220422T000000Z"
# DE0-G-recent snapshot (for libs updated since the harvest base).
DE0_G_RECENT = "ubuntu/jammy/20240130T000000Z"
# DE-G1 snapshot — 2026-06-15.
SNAP = "ubuntu/jammy/20260615T000000Z"

DEH1_LIBS = {
    # libs DE-H1 already plants; DE-G1 references them in dependency_closure.
    "fontconfig-config", "foot", "hyprland", "libbrotli1", "libbsd0",
    "libcairo2", "libdatrie1", "libelf1", "libevdev2", "libfcft",
    "libffi8", "libfreetype6", "libfribidi0", "libglib2.0", "libglvnd",
    "libgraphite2-3", "libharfbuzz0b", "libinput", "libjson-c5",
    "libmd0", "libpango", "libpcre3", "libpixman", "libpng16-16",
    "libseat", "libthai0", "libwayland-cursor", "libx11-extras",
    "libxcb-extras", "libxcb1", "libxkbregistry", "sway", "waybar",
    "wlroots", "xdg-desktop-portal", "xdg-desktop-portal-wlr",
    "xkb-data", "zlib1g",
}
DE0_G_LIBS = {
    "dejavu-fonts", "fontconfig", "libdrm", "libwayland",
    "libxkbcommon", "mesa",
}

def dep(name, snapshot=None):
    return {
        "distro": "linux-graphics",
        "name": name,
        "snapshot": snapshot or DE0_G,
    }

def base_catalog(name, version, banner, deps, payload, pocket="main",
                 rationale=""):
    return {
        "dependency_closure": deps,
        "format_version": 1,
        "linux_version_banner": banner,
        "package": {
            "distro": "linux-graphics",
            "name": name,
            "snapshot": SNAP,
            "version": version,
        },
        "package_source": "ubuntu-jammy",
        "payload_files": payload,
        "provisioning_methods": [
            {"kind": "ubuntu-jammy-archive", "pocket": pocket}
        ],
        "runtime": "linux",
        "signed_envelope": None,
        "version_pin_rationale": rationale,
    }

def pf(deb_pkg, deb_url, sha256, size, files):
    return {
        "deb_pkg": deb_pkg,
        "deb_sha256": sha256,
        "deb_size_bytes": size,
        "deb_url": deb_url,
        "expected_files": files,
    }

def ef_bin(path):
    return {"kind": "binary", "path": path}

def ef_lib(path, soname=None):
    out = {"kind": "shared_library", "path": path}
    if soname:
        out["soname_link"] = soname
    return out

def ef_config(path):
    return {"kind": "config", "path": path}

def ef_data(path):
    return {"kind": "data", "path": path}

# ---------------------------------------------------------------------------
# DE-G1 catalog definitions.
# ---------------------------------------------------------------------------

CATALOGS = {}

# gdm.json
CATALOGS["gdm"] = base_catalog(
    "gdm", "42.0-1ubuntu7.22.04.4",
    "libgdm.so.1",
    [
        dep("libsystemd", SNAP),
        dep("accountsservice", SNAP),
        dep("libgnome-desktop", SNAP),
        dep("dconf", SNAP),
    ],
    [
        pf("gdm3",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gdm3/gdm3_42.0-1ubuntu7.22.04.4_amd64.deb",
           "d3361adfbc926c7e0d44643420b92ae61e966966c286aaff8759f14b0dc63fb3",
           313882,
           [
               ef_bin("usr/sbin/gdm3"),
               ef_bin("usr/bin/gdm-screenshot"),
               ef_bin("usr/libexec/gdm-session-worker"),
               ef_bin("usr/libexec/gdm-wayland-session"),
               ef_bin("usr/libexec/gdm-x-session"),
               ef_bin("usr/libexec/gdm-runtime-config"),
               ef_config("etc/pam.d/gdm-autologin"),
               ef_config("etc/pam.d/gdm-launch-environment"),
               ef_config("etc/pam.d/gdm-password"),
               ef_config("etc/dbus-1/system.d/gdm.conf"),
               ef_data("lib/systemd/system/gdm.service"),
           ]),
        pf("libgdm1",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gdm3/libgdm1_42.0-1ubuntu7.22.04.4_amd64.deb",
           "c485ee158139972bcd8417be852fc59bd4dc33e1d82d5757d8b0c03501332211",
           61924,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgdm.so.1.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libgdm.so.1"),
               ef_bin("usr/bin/gdmflexiserver"),
           ]),
    ],
    rationale=(
        "gdm3 42.0-1ubuntu7.22.04.4 is the jammy security-pocket build. "
        "Bundles gdm3 sbin + libgdm.so.1 client lib + 4 PAM stacks + the "
        "systemd unit + dbus system.d conf so the DE-G1 builder can plant "
        "the whole display manager from one catalog. Same multi-deb-per-"
        "catalog shape as DE-H1's sway.json (sway + swaybg)."
    ),
)

# gnome-shell.json
CATALOGS["gnome-shell"] = base_catalog(
    "gnome-shell", "42.9-0ubuntu2.3",
    "gnome-shell",
    [
        dep("mutter", SNAP),
        dep("libgjs", SNAP),
        dep("libgnome-desktop", SNAP),
        dep("libgcr3", SNAP),
        dep("libsoup2.4", SNAP),
        dep("libsecret", SNAP),
        dep("libpolkit", SNAP),
        dep("libgudev", SNAP),
        dep("libwacom", SNAP),
        dep("libxkbfile", SNAP),
        dep("libjson-glib", SNAP),
        dep("libstartup-notification", SNAP),
        dep("libcanberra", SNAP),
        dep("libcairo2"),
        dep("libpango"),
        dep("libharfbuzz0b"),
        dep("libsystemd", SNAP),
        dep("gsettings-desktop-schemas", SNAP),
        dep("dconf", SNAP),
        dep("adwaita-icon-theme", SNAP),
    ],
    [
        pf("gnome-shell",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-shell/gnome-shell_42.9-0ubuntu2.3_amd64.deb",
           "83876ed9b2fdae5e6796ab01386d6902c83818832c5b0b8162935588b6bebcc6",
           876690,
           [
               ef_bin("usr/bin/gnome-shell"),
               ef_bin("usr/bin/gnome-extensions"),
               ef_bin("usr/bin/gnome-shell-extension-tool"),
               ef_bin("usr/bin/gnome-shell-perf-tool"),
               ef_bin("usr/libexec/gnome-shell-calendar-server"),
               ef_bin("usr/libexec/gnome-shell-hotplug-sniffer"),
               ef_bin("usr/libexec/gnome-shell-perf-helper"),
               ef_bin("usr/libexec/gnome-shell-portal-helper"),
               ef_data("usr/share/applications/org.gnome.Shell.desktop"),
               ef_data("usr/share/applications/org.gnome.Shell.Extensions.desktop"),
           ]),
        pf("gnome-shell-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-shell/gnome-shell-common_42.9-0ubuntu2.3_all.deb",
           "1e85d446354f50892e185a4790e7545ae4da6d33c286e5171e45854e58f0520b",
           182900,
           []),
    ],
    rationale=(
        "gnome-shell 42.9-0ubuntu2.3 is the jammy security-pocket build. "
        "The JS-driven compositor session UI. /usr/bin/gnome-shell embeds "
        "gjs + libmozjs-91; cross-referenced via libgjs.json + libmozjs91.json. "
        "gnome-shell-common ships the JS sources under /usr/share/gnome-shell/ "
        "(full tree planted via the catalog's --full-extract path so the "
        "in-process JS module loader walks it at startup; same xkb-data / "
        "fontconfig-config / waybar full-tree-copy class DE-H1 introduced)."
    ),
)

# mutter.json
CATALOGS["mutter"] = base_catalog(
    "mutter", "42.9-0ubuntu9",
    "libmutter-10.so.0",
    [
        dep("libwayland"),
        dep("libxkbcommon"),
        dep("libdrm"),
        dep("mesa"),
        dep("libgnome-desktop", SNAP),
        dep("libgraphene", SNAP),
        dep("libpixman"),
        dep("libcairo2"),
        dep("libpango"),
        dep("libharfbuzz0b"),
        dep("libgudev", SNAP),
        dep("libwacom", SNAP),
        dep("libinput"),
        dep("libxkbregistry"),
        dep("libxkbcommon-x11", SNAP),
        dep("libxkbfile", SNAP),
        dep("libjson-glib", SNAP),
        dep("libstartup-notification", SNAP),
        dep("libsystemd", SNAP),
        dep("libpipewire", SNAP),
        dep("libxcb-extras"),
        dep("libxcb1"),
        dep("libglvnd"),
    ],
    [
        pf("mutter",
           "http://archive.ubuntu.com/ubuntu/pool/universe/m/mutter/mutter_42.9-0ubuntu9_amd64.deb",
           "a2dc1671d2e32ed4186331d84e63bfb620d61ddaeb6fbf6932812b157320fbd3",
           107640,
           [
               ef_bin("usr/bin/mutter"),
               ef_bin("usr/libexec/mutter-restart-helper"),
           ]),
        pf("libmutter-10-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/m/mutter/libmutter-10-0_42.9-0ubuntu9_amd64.deb",
           "62bd3b33d19f2ae3648325212853f5608ddba24b8263b542d62e29f50ae93ab1",
           1379608,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libmutter-10.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libmutter-10.so.0"),
               ef_lib("usr/lib/x86_64-linux-gnu/mutter-10/libmutter-clutter-10.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/mutter-10/libmutter-clutter-10.so.0"),
               ef_lib("usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-10.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-10.so.0"),
               ef_lib("usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-pango-10.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/mutter-10/libmutter-cogl-pango-10.so.0"),
           ]),
        pf("mutter-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/m/mutter/mutter-common_42.9-0ubuntu9_all.deb",
           "378be9316b634f79cfd6ffd3b2398f84ee7638ebd8166c4cc3c992634ef0ceb6",
           13410,
           []),
    ],
    pocket="universe",
    rationale=(
        "mutter 42.9-0ubuntu9 is the jammy universe release build. "
        "Wayland compositor + window manager embedded by gnome-shell. "
        "Three .debs: mutter (the CLI; jammy universe), libmutter-10-0 (the "
        "shared lib; main), mutter-common (data files; main). The libmutter "
        ".deb also ships the clutter/cogl rendering sub-libs under "
        "mutter-10/ — those need a dedicated ld.so.conf.d entry that the "
        "DE-G1 build script adds explicitly (the lib search path "
        "/opt/reproos-linux/store/<hash>/usr/lib/x86_64-linux-gnu/mutter-10/)."
    ),
)

# gnome-session.json
CATALOGS["gnome-session"] = base_catalog(
    "gnome-session", "42.0-1ubuntu2",
    "gnome-session",
    [
        dep("libsystemd", SNAP),
        dep("gsettings-desktop-schemas", SNAP),
        dep("dconf", SNAP),
    ],
    [
        pf("gnome-session-bin",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-session/gnome-session-bin_42.0-1ubuntu2_amd64.deb",
           "53a1ddf0752af0d9319ecd1e6c25852a99b822770da7dc4b9cb63f235d22b65f",
           122532,
           [
               ef_bin("usr/bin/gnome-session"),
               ef_bin("usr/bin/gnome-session-custom-session"),
               ef_bin("usr/bin/gnome-session-inhibit"),
               ef_bin("usr/bin/gnome-session-quit"),
               ef_bin("usr/libexec/gnome-session-binary"),
               ef_bin("usr/libexec/gnome-session-ctl"),
               ef_bin("usr/libexec/gnome-session-failed"),
               ef_bin("usr/libexec/run-systemd-session"),
           ]),
        pf("gnome-session-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-session/gnome-session-common_42.0-1ubuntu2_all.deb",
           "67be5c1c897589dacfdc4430ad9727f81fd02cebeaf13255dd0ac09c6a50a161",
           12640,
           []),
    ],
    rationale=(
        "gnome-session 42.0-1ubuntu2. The session manager. /usr/bin/gnome-session "
        "is the entry point invoked by repro-start-gnome.sh; it execs "
        "gnome-shell after wiring up the systemd user instance. "
        "gnome-session-common is an all-arch deb shipping mime defaults."
    ),
)

# gnome-settings-daemon.json
CATALOGS["gnome-settings-daemon"] = base_catalog(
    "gnome-settings-daemon", "42.1-1ubuntu2.2",
    "gsd-xsettings",
    [
        dep("libsystemd", SNAP),
        dep("libgnome-desktop", SNAP),
        dep("libcanberra", SNAP),
        dep("libpolkit", SNAP),
        dep("libwacom", SNAP),
        dep("dconf", SNAP),
        dep("gsettings-desktop-schemas", SNAP),
    ],
    [
        pf("gnome-settings-daemon",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-settings-daemon/gnome-settings-daemon_42.1-1ubuntu2.2_amd64.deb",
           "8b87b2ccec10f42c0e0b888a94621cc5881cbc2f087707b78f9da6fb8aaf47c9",
           328708,
           [
               ef_bin("usr/libexec/gsd-a11y-settings"),
               ef_bin("usr/libexec/gsd-color"),
               ef_bin("usr/libexec/gsd-datetime"),
               ef_bin("usr/libexec/gsd-housekeeping"),
               ef_bin("usr/libexec/gsd-keyboard"),
               ef_bin("usr/libexec/gsd-media-keys"),
               ef_bin("usr/libexec/gsd-power"),
               ef_bin("usr/libexec/gsd-rfkill"),
               ef_bin("usr/libexec/gsd-screensaver-proxy"),
               ef_bin("usr/libexec/gsd-sharing"),
               ef_bin("usr/libexec/gsd-smartcard"),
               ef_bin("usr/libexec/gsd-sound"),
               ef_bin("usr/libexec/gsd-wacom"),
               ef_bin("usr/libexec/gsd-xsettings"),
           ]),
        pf("gnome-settings-daemon-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-settings-daemon/gnome-settings-daemon-common_42.1-1ubuntu2.2_all.deb",
           "bf34942d0cb5012d3725d89a54e153bc75abcada5ced230fac7485ed0b1f8eb9",
           17588,
           []),
    ],
    rationale=(
        "gnome-settings-daemon 42.1-1ubuntu2.2. 14 gsd-* libexec daemons "
        "the gnome-session pulls in via XDG-autostart. Skipping the "
        "usb-protection / wwan / print-notifications / printer / "
        "backlight-helper / wacom-oled-helper sub-helpers in expected_files "
        "(present in the .deb but PoC doesn't smoke them)."
    ),
)

# libgnome-desktop.json
CATALOGS["libgnome-desktop"] = base_catalog(
    "libgnome-desktop", "42.9-0ubuntu1",
    "libgnome-desktop-3.so.19",
    [dep("libgtk4", SNAP), dep("libsystemd", SNAP)],
    [
        pf("libgnome-desktop-3-19",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-desktop/libgnome-desktop-3-19_42.9-0ubuntu1_amd64.deb",
           "46c846663486a41f3ac6805116933031574b6b5c0619fc035b611e26da533057",
           119858,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgnome-desktop-3.so.19.3.0",
                      soname="usr/lib/x86_64-linux-gnu/libgnome-desktop-3.so.19"),
           ]),
        pf("gnome-desktop3-data",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gnome-desktop/gnome-desktop3-data_42.9-0ubuntu1_all.deb",
           "1dd2569d0946fce4e6c724880622d7dca82586754d8c8990e56f199511ed1cb3",
           23276,
           []),
    ],
    rationale=(
        "libgnome-desktop 42.9-0ubuntu1. Helper lib for GNOME desktop "
        "components (parsing .desktop files, wallpaper lookup, monitor "
        "config). Hard-deped by gnome-shell + mutter + gnome-settings-daemon."
    ),
)

# libgjs.json
CATALOGS["libgjs"] = base_catalog(
    "libgjs", "1.72.4-0ubuntu0.22.04.4",
    "libgjs.so.0",
    [dep("libmozjs91", SNAP), dep("libcairo2"), dep("libsystemd", SNAP)],
    [
        pf("libgjs0g",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gjs/libgjs0g_1.72.4-0ubuntu0.22.04.4_amd64.deb",
           "dbcab727ea3d7b3d3195f18eb24b653591b7844e6369caeb369a2376bb566abf",
           401946,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgjs.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libgjs.so.0"),
           ]),
    ],
    rationale=(
        "libgjs 1.72.4-0ubuntu0.22.04.4 is the jammy security-pocket build. "
        "gjs is the JS engine binding gnome-shell + the gsd-* daemons consume. "
        "Embeds SpiderMonkey 91 via libmozjs-91.so.0."
    ),
)

# libmozjs91.json
CATALOGS["libmozjs91"] = base_catalog(
    "libmozjs91", "91.10.0-0ubuntu1",
    "libmozjs-91.so.0",
    [],
    [
        pf("libmozjs-91-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/m/mozjs91/libmozjs-91-0_91.10.0-0ubuntu1_amd64.deb",
           "ffc96561eaa7e2d04d64bad8dc8d7a472c9f1f393b091b01c1164c6b47ef3353",
           4070940,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libmozjs-91.so.91.10.0",
                      soname="usr/lib/x86_64-linux-gnu/libmozjs-91.so.0"),
           ]),
    ],
    rationale=(
        "libmozjs-91-0 91.10.0-0ubuntu1. SpiderMonkey 91 — Mozilla's JS engine. "
        "Single largest dep in DE-G1 (4 MB compressed, 12 MB extracted). "
        "Hard-required by libgjs; gnome-shell would fail to load without it. "
        "Note: SONAME is libmozjs-91.so.0 (not .91), and the on-disk filename "
        "is libmozjs-91.so.91.10.0 — Mozilla's split-version convention. The "
        "DE-G1 build script's soname-link logic handles this."
    ),
)

# gjs.json
CATALOGS["gjs"] = base_catalog(
    "gjs", "1.72.4-0ubuntu0.22.04.4",
    "gjs-console",
    [dep("libgjs", SNAP)],
    [
        pf("gjs",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gjs/gjs_1.72.4-0ubuntu0.22.04.4_amd64.deb",
           "9f06e574447cc06bd0a680eb95e6aa41563c7945212cfff1e5218f267d508bc3",
           105664,
           [
               ef_bin("usr/bin/gjs-console"),
           ]),
    ],
    rationale=(
        "gjs 1.72.4-0ubuntu0.22.04.4. CLI wrapper around libgjs0g, used by "
        "the DE-G2 integration test smoke probe (`gjs-console --version`). "
        "Optional for the runtime session; gnome-shell embeds libgjs directly."
    ),
)

# libgtk4.json
CATALOGS["libgtk4"] = base_catalog(
    "libgtk4", "4.6.9+ds-0ubuntu0.22.04.2",
    "libgtk-4.so.1",
    [
        dep("libgraphene", SNAP),
        dep("libcairo2"),
        dep("libpango"),
        dep("libharfbuzz0b"),
        dep("libxkbcommon"),
        dep("libwayland"),
        dep("libepoxy0", SNAP),
        dep("libsystemd", SNAP),
    ],
    [
        pf("libgtk-4-1",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gtk4/libgtk-4-1_4.6.9+ds-0ubuntu0.22.04.2_amd64.deb",
           "69bbd3dbb1c437563d625ab15b43d0dd969f151fd66c772e845a8103bbe68640",
           2865660,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgtk-4.so.1.600.9",
                      soname="usr/lib/x86_64-linux-gnu/libgtk-4.so.1"),
           ]),
        pf("libgtk-4-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gtk4/libgtk-4-common_4.6.9+ds-0ubuntu0.22.04.2_all.deb",
           "572d2534074328f08b68ab94e5299eb247192552fd5b5f5a13a3d9334dd72da8",
           662152,
           []),
    ],
    rationale=(
        "libgtk-4 4.6.9+ds-0ubuntu0.22.04.2 is the jammy security-pocket build. "
        "GTK 4 — the GUI toolkit xdg-desktop-portal-gtk + libadwaita-using "
        "apps need. Largest single .deb in DE-G1 (~3 MB compressed). "
        "DE-H1 already supplies libcairo2 / libpango / libharfbuzz0b which "
        "GTK4 hard-deps."
    ),
)

# dconf.json
CATALOGS["dconf"] = base_catalog(
    "dconf", "0.40.0-3ubuntu0.1",
    "libdconf.so.1",
    [dep("libglib2.0")],
    [
        pf("libdconf1",
           "http://archive.ubuntu.com/ubuntu/pool/main/d/dconf/libdconf1_0.40.0-3ubuntu0.1_amd64.deb",
           "8cc719e288131b7232a22d58f4c32e96f59a9ff23378a7c6f4f401eb06f99b63",
           40498,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libdconf.so.1.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libdconf.so.1"),
           ]),
        pf("dconf-service",
           "http://archive.ubuntu.com/ubuntu/pool/main/d/dconf/dconf-service_0.40.0-3ubuntu0.1_amd64.deb",
           "cc9d865340084258519eb69d1e53119aa389b0b0d19f0e3f433c2adc4575de7b",
           28092,
           [
               ef_bin("usr/libexec/dconf-service"),
           ]),
        pf("dconf-gsettings-backend",
           "http://archive.ubuntu.com/ubuntu/pool/main/d/dconf/dconf-gsettings-backend_0.40.0-3ubuntu0.1_amd64.deb",
           "90632fbb3a6865d36a8ec17e4152f419efd7e94768c68a5e7fa5b60cdce47a94",
           22742,
           [
               # The GIO module has no SONAME (GLib loads it by path).
               ef_lib("usr/lib/x86_64-linux-gnu/gio/modules/libdconfsettings.so"),
           ]),
    ],
    rationale=(
        "dconf 0.40.0-3ubuntu0.1. Three .debs bundled: libdconf1 (client "
        "lib), dconf-service (daemon), dconf-gsettings-backend (GIO module). "
        "**Cascade-class hidden dep:** without dconf-gsettings-backend, "
        "g_settings_new() returns the memory backend and gnome-settings-daemon "
        "panics on first write. The GIO module under usr/lib/.../gio/modules/ "
        "has no SONAME (GLib loads it by absolute path); the DE-G1 build "
        "script does NOT create a soname-link for it."
    ),
)

# gsettings-desktop-schemas.json
CATALOGS["gsettings-desktop-schemas"] = base_catalog(
    "gsettings-desktop-schemas", "42.0-1ubuntu1",
    "gsettings-desktop-schemas",
    [dep("libglib2.0")],
    [
        pf("gsettings-desktop-schemas",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gsettings-desktop-schemas/gsettings-desktop-schemas_42.0-1ubuntu1_all.deb",
           "5b420af7d77735d1bcc0494134b6810d20d168cd9407febed32d77baccd9e993",
           31068,
           []),
    ],
    rationale=(
        "gsettings-desktop-schemas 42.0-1ubuntu1. all-arch deb; ships "
        "/usr/share/glib-2.0/schemas/*.xml. Without this, mutter + "
        "gnome-shell + gsd-* all log 'Schema not installed' on startup. "
        "Full-extract: copied via the catalog's full-tree path (parallel to "
        "DE-H1's xkb-data / fontconfig-config handling)."
    ),
)

# libgraphene.json
CATALOGS["libgraphene"] = base_catalog(
    "libgraphene", "1.10.8-1",
    "libgraphene-1.0.so.0",
    [],
    [
        pf("libgraphene-1.0-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/graphene/libgraphene-1.0-0_1.10.8-1_amd64.deb",
           "8af39f36795940e3fd7d5813a13955b128827fa2e7d122828b81008051886cd3",
           48218,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgraphene-1.0.so.0.1000.8",
                      soname="usr/lib/x86_64-linux-gnu/libgraphene-1.0.so.0"),
           ]),
    ],
    rationale=(
        "libgraphene 1.10.8-1. Math primitives library (vec3/4, mat4, "
        "quaternions). libmutter-10 + libgtk-4 + libclutter (vendored "
        "inside libmutter) all hard-link it."
    ),
)

# libgcr3.json
CATALOGS["libgcr3"] = base_catalog(
    "libgcr3", "3.40.0-4",
    "libgcr-base-3.so.1",
    [],
    [
        pf("libgcr-base-3-1",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gcr/libgcr-base-3-1_3.40.0-4_amd64.deb",
           "4f4e926a9e917d1fb79c5bf8e798c0523bba8447e0395fa19a1ff8e5f58a164a",
           208962,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgcr-base-3.so.1.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libgcr-base-3.so.1"),
           ]),
        pf("libgck-1-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/g/gcr/libgck-1-0_3.40.0-4_amd64.deb",
           "ebf4ffb2e0c3eb0bf4829b9e27bd2e4af37c2721ca5c48e7341a1f7779d44d00",
           81380,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgck-1.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libgck-1.so.0"),
           ]),
    ],
    rationale=(
        "libgcr3 3.40.0-4 + libgck 3.40.0-4 (both ship from the gcr source "
        "package). GCR is GNOME's PKCS#11 + DBus secret-service binding; "
        "libgck is the PKCS#11 wrapper. gnome-shell + gnome-settings-daemon "
        "link libgcr-base for the keyring sub-component (read-only)."
    ),
)

# libjson-glib.json
CATALOGS["libjson-glib"] = base_catalog(
    "libjson-glib", "1.6.6-1build1",
    "libjson-glib-1.0.so.0",
    [dep("libglib2.0")],
    [
        pf("libjson-glib-1.0-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/j/json-glib/libjson-glib-1.0-0_1.6.6-1build1_amd64.deb",
           "b8c0a840e8ea5aad3dbad375d7fea64cf8f734a89a12115aae3527a8514b4329",
           69866,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libjson-glib-1.0.so.0.600.6",
                      soname="usr/lib/x86_64-linux-gnu/libjson-glib-1.0.so.0"),
           ]),
    ],
    rationale=(
        "libjson-glib 1.6.6-1build1. JSON parser for GLib. gnome-shell + "
        "libmutter + xdg-desktop-portal-gnome dep on it for parsing manifest "
        "JSON files at runtime."
    ),
)

# libsm.json
CATALOGS["libsm"] = base_catalog(
    "libsm", "2:1.2.3-1build2",
    "libSM.so.6",
    [dep("libice", SNAP)],
    [
        pf("libsm6",
           "http://archive.ubuntu.com/ubuntu/pool/main/libs/libsm/libsm6_1.2.3-1build2_amd64.deb",
           "e652e286a79d9e8e15189d79b290bdce20aca83651f3dfed1b9b7dc0bbf0702f",
           16736,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libSM.so.6.0.1",
                      soname="usr/lib/x86_64-linux-gnu/libSM.so.6"),
           ]),
    ],
    rationale=(
        "libsm6 2:1.2.3-1build2. X11 Session Management Protocol library. "
        "Cairo + gtk3 hard-link via libICE; gnome-shell pulls it via "
        "libcairo2's X11 backend even on a Wayland-only session."
    ),
)

# libice.json
CATALOGS["libice"] = base_catalog(
    "libice", "2:1.0.10-1build2",
    "libICE.so.6",
    [],
    [
        pf("libice6",
           "http://archive.ubuntu.com/ubuntu/pool/main/libi/libice/libice6_1.0.10-1build2_amd64.deb",
           "eea6d52d12ad610d70b0f70c825ed3c560dafb09f4c272e3c6b0b493d984d13f",
           42606,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libICE.so.6.3.0",
                      soname="usr/lib/x86_64-linux-gnu/libICE.so.6"),
           ]),
    ],
    rationale=(
        "libice6 2:1.0.10-1build2. X11 Inter-Client Exchange library. "
        "libSM hard-deps it; cairo's X11 backend links it. Wayland-only "
        "session still needs it because cairo's X11 backend is compiled in "
        "unconditionally on jammy."
    ),
)

# libcanberra.json
CATALOGS["libcanberra"] = base_catalog(
    "libcanberra", "0.30-10ubuntu1.22.04.1",
    "libcanberra.so.0",
    [],
    [
        pf("libcanberra0",
           "http://archive.ubuntu.com/ubuntu/pool/main/libc/libcanberra/libcanberra0_0.30-10ubuntu1.22.04.1_amd64.deb",
           "5d79dfe622dc2f88f20d4a827fa840ec4b90a2695f2ffe0554c643cc3524e640",
           40042,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libcanberra.so.0.2.5",
                      soname="usr/lib/x86_64-linux-gnu/libcanberra.so.0"),
           ]),
    ],
    rationale=(
        "libcanberra 0.30-10ubuntu1.22.04.1 is the jammy security-pocket build. "
        "Event sound library. Ships a libcanberra-alsa.so plugin too, but "
        "the alsa-lib stack is NOT in our closure, so canberra falls back "
        "to the null backend at runtime — events are silent but gsd-sound "
        "doesn't crash."
    ),
)

# libgudev.json
CATALOGS["libgudev"] = base_catalog(
    "libgudev", "1:237-2build1",
    "libgudev-1.0.so.0",
    [],
    [
        pf("libgudev-1.0-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/libg/libgudev/libgudev-1.0-0_237-2build1_amd64.deb",
           "a6683b34922bbf31c93e4903eb796d357ea0909b212a453f2c361c2919f108d8",
           16266,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libgudev-1.0.so.0.3.0",
                      soname="usr/lib/x86_64-linux-gnu/libgudev-1.0.so.0"),
           ]),
    ],
    rationale=(
        "libgudev 1:237-2build1. GObject wrapper around libudev. Hard-deped "
        "by libmutter + gnome-shell + gsd-rfkill + gsd-power."
    ),
)

# libstartup-notification.json
CATALOGS["libstartup-notification"] = base_catalog(
    "libstartup-notification", "0.12-6build2",
    "libstartup-notification-1.so.0",
    [dep("libxcb1"), dep("libxcb-extras")],
    [
        pf("libstartup-notification0",
           "http://archive.ubuntu.com/ubuntu/pool/main/s/startup-notification/libstartup-notification0_0.12-6build2_amd64.deb",
           "322f39b6748e4d8ed339b4cd8dd6880d9d33e62acca3c0a6c8aef60ec7bc5443",
           19536,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libstartup-notification-1.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libstartup-notification-1.so.0"),
           ]),
    ],
    rationale=(
        "libstartup-notification0 0.12-6build2. X11 startup notification "
        "protocol helper. libmutter + gnome-shell link it for the splash "
        "screen path even on Wayland."
    ),
)

# libwacom.json
CATALOGS["libwacom"] = base_catalog(
    "libwacom", "2.2.0-1",
    "libwacom.so.9",
    [dep("libgudev", SNAP)],
    [
        pf("libwacom9",
           "http://archive.ubuntu.com/ubuntu/pool/main/libw/libwacom/libwacom9_2.2.0-1_amd64.deb",
           "8d2b65dacab053530e7e205d476870adb34137247ed6f8f8182502a5fe879d8e",
           22028,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libwacom.so.9.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libwacom.so.9"),
           ]),
        pf("libwacom-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/libw/libwacom/libwacom-common_2.2.0-1_all.deb",
           "a54bf57ec81a2dc9ba624a99aa49dc7a933834411e902ed66f1cc2b4713394bd",
           54338,
           []),
    ],
    rationale=(
        "libwacom 2.2.0-1. Wacom tablet device database. libmutter + "
        "gsd-wacom dep on it. The -common deb is all-arch; ships "
        "/usr/share/libwacom/data/ which libwacom.so.9 walks at init."
    ),
)

# libxkbfile.json
CATALOGS["libxkbfile"] = base_catalog(
    "libxkbfile", "1:1.1.0-1build3",
    "libxkbfile.so.1",
    [dep("libx11-extras")],
    [
        pf("libxkbfile1",
           "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxkbfile/libxkbfile1_1.1.0-1build3_amd64.deb",
           "89ceb4a9420dd9f1f89c0488abc0002f55ddefaaa2209ccad8c3b3e3c9e21743",
           71826,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libxkbfile.so.1.0.2",
                      soname="usr/lib/x86_64-linux-gnu/libxkbfile.so.1"),
           ]),
    ],
    rationale=(
        "libxkbfile 1:1.1.0-1build3. Legacy X11 XKB keymap file loader. "
        "libmutter + gnome-shell link it for the X11 fallback keyboard "
        "layout path even on Wayland sessions."
    ),
)

# accountsservice.json
CATALOGS["accountsservice"] = base_catalog(
    "accountsservice", "22.07.5-2ubuntu1.5",
    "libaccountsservice.so.0",
    [dep("libsystemd", SNAP)],
    [
        pf("accountsservice",
           "http://archive.ubuntu.com/ubuntu/pool/main/a/accountsservice/accountsservice_22.07.5-2ubuntu1.5_amd64.deb",
           "95ef667f9ada1acb2629bb98d3aa004dcf49a694430ac46b72d9add43adc569d",
           69982,
           [
               ef_bin("usr/libexec/accounts-daemon"),
           ]),
        pf("libaccountsservice0",
           "http://archive.ubuntu.com/ubuntu/pool/main/a/accountsservice/libaccountsservice0_22.07.5-2ubuntu1.5_amd64.deb",
           "180fdaa976ea829588ae8a6a664e3b812c402394a6ef98996e808e2f034efb6c",
           62626,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libaccountsservice.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libaccountsservice.so.0"),
           ]),
    ],
    rationale=(
        "accountsservice 22.07.5-2ubuntu1.5 is the jammy security-pocket build. "
        "User account info via DBus. gdm3 + gnome-shell read user lists through "
        "it. /usr/libexec/accounts-daemon is the system DBus service worker."
    ),
)

# libsoup2.4.json
CATALOGS["libsoup2.4"] = base_catalog(
    "libsoup2.4", "2.74.2-3ubuntu0.6",
    "libsoup-2.4.so.1",
    [dep("libnss", SNAP), dep("libglib2.0")],
    [
        pf("libsoup2.4-1",
           "http://archive.ubuntu.com/ubuntu/pool/main/libs/libsoup2.4/libsoup2.4-1_2.74.2-3ubuntu0.6_amd64.deb",
           "a66cd9ff6e880e90534b7561fd72e005ad31dbab2e26c1d19c2d32bb5738aa5f",
           287638,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libsoup-2.4.so.1.11.2",
                      soname="usr/lib/x86_64-linux-gnu/libsoup-2.4.so.1"),
           ]),
        pf("libsoup2.4-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/libs/libsoup2.4/libsoup2.4-common_2.74.2-3ubuntu0.6_all.deb",
           "1d05a4b0b79bea1e77b48bc056e83fd53d06cc1990cb84360284cce12616a8cd",
           4778,
           []),
    ],
    rationale=(
        "libsoup 2.74.2-3ubuntu0.6 is the jammy security-pocket build. "
        "HTTP library v2 (the legacy API; gnome-shell 42 still uses v2; "
        "v3 was introduced for GNOME 43+)."
    ),
)

# libsecret.json
CATALOGS["libsecret"] = base_catalog(
    "libsecret", "0.20.5-2",
    "libsecret-1.so.0",
    [dep("libglib2.0")],
    [
        pf("libsecret-1-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/libs/libsecret/libsecret-1-0_0.20.5-2_amd64.deb",
           "60bd53073b4d76ce67f2990eaf1e9b9c5279349a17d7a2bae0c2f9976f4ce58a",
           123936,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libsecret-1.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libsecret-1.so.0"),
           ]),
        pf("libsecret-common",
           "http://archive.ubuntu.com/ubuntu/pool/main/libs/libsecret/libsecret-common_0.20.5-2_all.deb",
           "f1f982938057869a22b322c95363ea21a89658b31f3bd18ea87500132f2445c0",
           4278,
           []),
    ],
    rationale=(
        "libsecret 0.20.5-2. Secret Service API client library. gnome-shell "
        "+ gnome-keyring link it; without it gnome-shell's gnome-keyring "
        "integration logs warnings but the shell continues."
    ),
)

# libpolkit.json
CATALOGS["libpolkit"] = base_catalog(
    "libpolkit", "0.105-33ubuntu0.1",
    "libpolkit-gobject-1.so.0",
    [dep("libsystemd", SNAP)],
    [
        pf("libpolkit-agent-1-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/p/policykit-1/libpolkit-agent-1-0_0.105-33ubuntu0.1_amd64.deb",
           "bf78fbd0e46b0faf3e942dd88260ce216f310520ebb137c2354338622a14da41",
           16874,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libpolkit-agent-1.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libpolkit-agent-1.so.0"),
           ]),
        pf("libpolkit-gobject-1-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/p/policykit-1/libpolkit-gobject-1-0_0.105-33ubuntu0.1_amd64.deb",
           "e91137381c4645d4c7cc4fd5ec69722ce9cd7d43dd61753f753010a50646fe78",
           43316,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libpolkit-gobject-1.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libpolkit-gobject-1.so.0"),
           ]),
    ],
    rationale=(
        "libpolkit 0.105-33ubuntu0.1 is the jammy security-pocket build. "
        "Polkit client libraries (agent + gobject). gnome-shell + gsd-color "
        "+ gsd-power link them for auth checks. The polkit daemon itself "
        "is NOT shipped; auth checks fail closed."
    ),
)

# xdg-desktop-portal-gnome.json
CATALOGS["xdg-desktop-portal-gnome"] = base_catalog(
    "xdg-desktop-portal-gnome", "42.1-0ubuntu2",
    "xdg-desktop-portal-gnome",
    [dep("xdg-desktop-portal"), dep("libgtk4", SNAP)],
    [
        pf("xdg-desktop-portal-gnome",
           "http://archive.ubuntu.com/ubuntu/pool/main/x/xdg-desktop-portal-gnome/xdg-desktop-portal-gnome_42.1-0ubuntu2_amd64.deb",
           "3190750a962bb0c95695cc6d2430ea76e642bfa2b814df294a42fa1f5b9db690",
           106766,
           [
               ef_bin("usr/libexec/xdg-desktop-portal-gnome"),
           ]),
    ],
    rationale=(
        "xdg-desktop-portal-gnome 42.1-0ubuntu2. GNOME-specific backend for "
        "the xdg-desktop-portal framework (file-chooser, screenshot, "
        "screencast). DE-H1 ships the framework + the wlr backend; DE-G1 "
        "swaps in the gnome backend instead."
    ),
)

# xdg-desktop-portal-gtk.json
CATALOGS["xdg-desktop-portal-gtk"] = base_catalog(
    "xdg-desktop-portal-gtk", "1.14.0-1build1",
    "xdg-desktop-portal-gtk",
    [dep("xdg-desktop-portal"), dep("libgtk4", SNAP)],
    [
        pf("xdg-desktop-portal-gtk",
           "http://archive.ubuntu.com/ubuntu/pool/main/x/xdg-desktop-portal-gtk/xdg-desktop-portal-gtk_1.14.0-1build1_amd64.deb",
           "d3d60526948e4a32a2a6a1c840fd6168fc03e1383a0ce50ff3740527d4bfb8c2",
           87402,
           [
               ef_bin("usr/libexec/xdg-desktop-portal-gtk"),
           ]),
    ],
    rationale=(
        "xdg-desktop-portal-gtk 1.14.0-1build1. GTK-based backend for "
        "the xdg-desktop-portal framework. Routes appchooser + secret + "
        "settings portals through GTK."
    ),
)

# adwaita-icon-theme.json
CATALOGS["adwaita-icon-theme"] = base_catalog(
    "adwaita-icon-theme", "41.0-1ubuntu1",
    "adwaita-icon-theme",
    [],
    [
        pf("adwaita-icon-theme",
           "http://archive.ubuntu.com/ubuntu/pool/main/a/adwaita-icon-theme/adwaita-icon-theme_41.0-1ubuntu1_all.deb",
           "9391c87c5479507895be429434d6ebd60593e8f3a708fec6cd7950579128debc",
           3444050,
           []),
    ],
    rationale=(
        "adwaita-icon-theme 41.0-1ubuntu1. Default GNOME icon theme. "
        "Without this, mutter's cursor is undefined (X11 ? fallback) and "
        "gnome-shell logs 'icon not found' for every app. Full-extract: "
        "copied via the catalog's full-tree path (3.4 MB compressed; ~13 MB "
        "extracted to /usr/share/icons/Adwaita/)."
    ),
)

# libxkbcommon-x11.json
CATALOGS["libxkbcommon-x11"] = base_catalog(
    "libxkbcommon-x11", "1.4.0-1",
    "libxkbcommon-x11.so.0",
    [dep("libxkbcommon"), dep("libxcb1"), dep("libxcb-extras")],
    [
        pf("libxkbcommon-x11-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxkbcommon/libxkbcommon-x11-0_1.4.0-1_amd64.deb",
           "e29c40fab6e0f055218aee4c7e60cd61ea82283229d7ac7ac02e226e92a5b0d5",
           14368,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so.0.0.0",
                      soname="usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so.0"),
           ]),
    ],
    rationale=(
        "libxkbcommon-x11 1.4.0-1 (same source as DE0-G's libxkbcommon). "
        "The X11-specific helper. libmutter dep on it for the X11 "
        "fallback path."
    ),
)

# libpipewire.json
CATALOGS["libpipewire"] = base_catalog(
    "libpipewire", "0.3.48-1ubuntu3",
    "libpipewire-0.3.so.0",
    [dep("libsystemd", SNAP)],
    [
        pf("libpipewire-0.3-0",
           "http://archive.ubuntu.com/ubuntu/pool/main/p/pipewire/libpipewire-0.3-0_0.3.48-1ubuntu3_amd64.deb",
           "ed46b4bc8d650f96ccd2c80a3319d7db024fee33cd3415ec67f48c61f0d3a02c",
           273646,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libpipewire-0.3.so.0.348.0",
                      soname="usr/lib/x86_64-linux-gnu/libpipewire-0.3.so.0"),
           ]),
    ],
    rationale=(
        "libpipewire 0.3.48-1ubuntu3. PipeWire client shared library. "
        "Required by xdg-desktop-portal + gnome-shell + libmutter at "
        "DT_NEEDED load time. The PipeWire daemon (`pipewire`, "
        "`wireplumber`) is NOT planted; the client connects and ENOENTs, "
        "and gnome-shell falls back to 'no screencast' gracefully."
    ),
)

# libnss.json
CATALOGS["libnss"] = base_catalog(
    "libnss", "2:3.98-0ubuntu0.22.04.3",
    "libnss3.so",
    [],
    [
        pf("libnss3",
           "http://archive.ubuntu.com/ubuntu/pool/main/n/nss/libnss3_3.98-0ubuntu0.22.04.3_amd64.deb",
           "c293e2259e606b40680dee472ac5cf86ca80e6da9db631d7b4f5cb337a2f9b9e",
           1347212,
           [
               # libnss3.so is loaded by SONAME 'libnss3.so' (no version number).
               ef_lib("usr/lib/x86_64-linux-gnu/libnss3.so"),
               ef_lib("usr/lib/x86_64-linux-gnu/libnssutil3.so"),
               ef_lib("usr/lib/x86_64-linux-gnu/libsmime3.so"),
               ef_lib("usr/lib/x86_64-linux-gnu/libssl3.so"),
           ]),
        pf("libnspr4",
           "http://archive.ubuntu.com/ubuntu/pool/main/n/nspr/libnspr4_4.35-0ubuntu0.22.04.1_amd64.deb",
           "b3c96e4a61675c87f8d9655109346748847d859abc95f20493159d06b5aa30ef",
           119208,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libnspr4.so"),
               ef_lib("usr/lib/x86_64-linux-gnu/libplc4.so"),
               ef_lib("usr/lib/x86_64-linux-gnu/libplds4.so"),
           ]),
    ],
    rationale=(
        "libnss 2:3.98-0ubuntu0.22.04.3 + libnspr 4.35. Mozilla NSS (TLS / "
        "cert) + NSPR (portable runtime). Mozilla libs use SONAME == "
        "filename (no .0 suffix); the DE-G1 build script's soname-link "
        "logic treats these as no-link entries."
    ),
)

# libsystemd.json
CATALOGS["libsystemd"] = base_catalog(
    "libsystemd", "249.11-0ubuntu3.21",
    "libsystemd.so.0",
    [],
    [
        pf("libsystemd0",
           "http://archive.ubuntu.com/ubuntu/pool/main/s/systemd/libsystemd0_249.11-0ubuntu3.21_amd64.deb",
           "86cc91af9eaca8ab6c18cebe74f86b6ad08a07dd9faa52867f52f47e44b2c488",
           316362,
           [
               ef_lib("usr/lib/x86_64-linux-gnu/libsystemd.so.0.32.0",
                      soname="usr/lib/x86_64-linux-gnu/libsystemd.so.0"),
           ]),
    ],
    rationale=(
        "libsystemd 249.11-0ubuntu3.21 is the jammy security-pocket build. "
        "systemd client library (sd_journal_send, sd_notify, sd_bus_*). "
        "Hard-deped by gnome-shell + mutter + gnome-session + "
        "gnome-settings-daemon + gdm3. **Cascade-class hidden dep:** the R9 "
        "from-source systemd ships a libsystemd.so.0 but with different "
        "SONAME bytes; planting jammy's own copy avoids ABI roulette."
    ),
)

# ---------------------------------------------------------------------------
# Serialize.
# ---------------------------------------------------------------------------

def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    for name, catalog in sorted(CATALOGS.items()):
        path = os.path.join(out_dir, f"{name}.json")
        # Sort keys at every level + indent=2 + LF newlines for byte-stability.
        with open(path, "w", newline="\n") as f:
            json.dump(catalog, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"wrote {path}")
    print(f"DONE: {len(CATALOGS)} catalogs")

if __name__ == "__main__":
    main()
