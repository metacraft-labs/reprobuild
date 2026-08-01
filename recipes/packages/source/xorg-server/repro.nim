## Source-built Xorg server for the ReproOS SDDM login session.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package xorgServerSource:
  versions:
    "21.1.24":
      sourceRevision = "xorg-server-21.1.24"
      sourceUrl = "https://gitlab.freedesktop.org/xorg/xserver/-/archive/xorg-server-21.1.24/xserver-xorg-server-21.1.24.tar.gz"
      sourceRepository = "https://gitlab.freedesktop.org/xorg/xserver"

  fetch:
    url: "https://gitlab.freedesktop.org/xorg/xserver/-/archive/xorg-server-21.1.24/xserver-xorg-server-21.1.24.tar.gz"
    sha256: "5051b8a339b9497cb573b57871fa7311a2d55c39c3d1cecd051804bbfe9c18e2"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=1.0"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "python3"

  buildDeps:
    "dbus"
    "systemd"
    "libdrm >=2.4.110"
    "pixman >=0.42"
    "libxfont2"
    "font-util"
    "libpciaccess"
    "libxkbfile"
    "libxshmfence"
    "libxcvt >=0.1.1"
    "xkbcomp"
    "nettle >=3.7"
    "xorgproto"
    "xtrans"
    "libxau"

  config:
    discard
  executable xorgServer:
    discard

  build:
    setCurrentOwningPackageOverride("xorgServerSource")
    try:
      let opts = @[
        "xorg=true",
        "xephyr=false",
        "xnest=false",
        "xvfb=false",
        "xwin=false",
        "glamor=false",
        "glx=false",
        "xdmcp=false",
        "xdm-auth-1=false",
        "secure-rpc=false",
        "dtrace=false",
        "dri1=false",
        "dri2=false",
        "dri3=false",
        "sha1=libnettle",
        "systemd_logind=true",
        "udev=true",
        "suid_wrapper=false",
        "default_font_path=/usr/share/fonts/X11/misc,/usr/share/fonts/X11/TTF,/usr/share/fonts/X11/OTF,/usr/share/fonts/X11/Type1,/usr/share/fonts/X11/100dpi,/usr/share/fonts/X11/75dpi",
        "xkb_bin_dir=/usr/bin",
        "xkb_dir=/usr/share/X11/xkb",
        "xkb_default_rules=evdev",
        "xkb_default_model=pc105",
        "xkb_default_layout=us",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      pkg.installTreeMirror()
      discard pkg.executableAlias("xorgServer", sourceName = "Xorg")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "dbus"
    "systemd"
    "libdrm >=2.4.110"
    "pixman >=0.42"
    "libxfont2"
    "libpciaccess"
    "libxkbfile"
    "libxcvt >=0.1.1"
    "nettle >=3.7"
    "xkeyboard-config"
    "xkbcomp"
