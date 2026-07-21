## Source build for the PulseAudio client ABI. ReproOS runs PipeWire's
## Pulse-compatible server, so the historical PulseAudio daemon is omitted.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package pulseaudioSource:
  versions:
    "17.0":
      sourceRevision = "v17.0"
      sourceUrl = "https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-17.0.tar.xz"
      sourceRepository = "https://gitlab.freedesktop.org/pulseaudio/pulseaudio.git"

  fetch:
    url: "https://www.freedesktop.org/software/pulseaudio/releases/pulseaudio-17.0.tar.xz"
    sha256: "053794d6671a3e397d849e478a80b82a63cb9d8ca296bd35b73317bb5ceb87b5"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.61"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "m4"

  buildDeps:
    "libsndfile >=1.2"

  config:
    discard

  library libPulse:
    discard

  library libPulseSimple:
    discard

  build:
    setCurrentOwningPackageOverride("pulseaudioSource")
    try:
      let opts = @[
        "daemon=false",
        "client=true",
        "doxygen=false",
        "man=false",
        "tests=false",
        "database=simple",
        "alsa=disabled",
        "asyncns=disabled",
        "avahi=disabled",
        "bluez5=disabled",
        "bluez5-gstreamer=disabled",
        "bluez5-native-headset=false",
        "bluez5-ofono-headset=false",
        "consolekit=disabled",
        "dbus=disabled",
        "elogind=disabled",
        "fftw=disabled",
        "glib=disabled",
        "gsettings=disabled",
        "gstreamer=disabled",
        "gtk=disabled",
        "jack=disabled",
        "lirc=disabled",
        "openssl=disabled",
        "orc=disabled",
        "oss-output=disabled",
        "samplerate=disabled",
        "soxr=disabled",
        "speex=disabled",
        "systemd=disabled",
        "tcpwrap=disabled",
        "udev=disabled",
        "valgrind=disabled",
        "webrtc-aec=disabled",
        "x11=disabled",
      ]
      let pkg = meson_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libPulse")
      discard pkg.library("libPulseSimple")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "libsndfile >=1.2"
