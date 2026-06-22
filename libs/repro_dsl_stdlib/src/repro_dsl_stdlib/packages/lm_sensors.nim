## DSL-port M9.R.15q.11.1 — stdlib provisioning stub for ``lm-sensors``.
##
## ``lm-sensors`` (libsensors) is the Linux hardware-monitoring library
## that exposes CPU / motherboard temperature / fan-speed sensors via
## ``/sys/class/hwmon``. ksysguard's CMakeLists.txt declares
## ``find_package(Sensors)`` + ``set_package_properties(Sensors
## PROPERTIES TYPE REQUIRED ...)`` for the hardware-sensor surface —
## without it ``feature_summary(REQUIRED_PACKAGES_NOT_FOUND
## FATAL_ON_MISSING_REQUIRED_PACKAGES)`` aborts the configure run with
## ``REQUIRED package(s) are missing``.
##
## The KDE-vendored ``FindSensors.cmake`` shipped with ksysguard's
## source tree finds ``sensors/sensors.h`` + the ``sensors`` library.
##
## We register the canonical package name ``lm-sensors`` (matching the
## nixpkgs derivation's ``pname``) so the dep declarations on ksysguard
## use the upstream-conventional spelling.
##
## ## Provisioning channel — nixpkgs#lm_sensors^*
##
## The ``^*`` multi-output realization brings the headers (dev output)
## AND the runtime ``libsensors.so`` (out output) per the M9.R.14f.10
## pattern.

import repro_project_dsl

package `lm-sensors`:
  provisioning:
    nixPackage "nixpkgs#lm_sensors^*", executablePath = "lib/libsensors.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
