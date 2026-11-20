## ``python3-opentelemetry`` — a Python interpreter that imports the
## OpenTelemetry Python SDK.
##
## For a program or test that must trace with the real SDK, such as a backend
## fixture that puts a span's ``traceparent`` into the page it serves. The
## package's executable is the interpreter itself: a consumer runs
## ``<prefix>/python.exe`` (Windows) or ``<prefix>/bin/python3`` and imports
## ``opentelemetry`` with no further setup. It sets no ``PYTHONPATH`` and needs
## none.
##
## ## Linux and macOS — nixpkgs
##
## ``python3.withPackages (ps: [ ps.opentelemetry-sdk ])`` from the stdlib's
## pinned nixpkgs (``nix/python3-opentelemetry-1.34.0/default.nix``). At that
## pin the SDK is 1.34.0, with ``opentelemetry-api`` 1.34.0 and
## ``opentelemetry-semantic-conventions`` 0.55b0: the versions the Windows arms
## below pin, so both realize the same SDK. Its ``typing-extensions``,
## ``importlib-metadata`` and ``zipp`` are also the versions the Windows arms
## pin. The interpreters differ: nixpkgs' ``python3`` is 3.13 at that pin,
## the Windows arms' is 3.12.
##
## ## Windows — the embeddable CPython plus pinned wheels
##
## * **The interpreter** is python.org's embeddable CPython 3.12.10, the same
##   archive ``packages/python3.nim`` realizes on x86_64 (its digest agrees),
##   and its arm64 build for aarch64. Both are native builds.
##
## * **The SDK** is six pure-Python wheels from PyPI: ``opentelemetry-sdk``
##   1.34.0 and its complete runtime dependency closure (``requires_dist`` of
##   each, read 2026-11-20): ``opentelemetry-api`` 1.34.0,
##   ``opentelemetry-semantic-conventions`` 0.55b0, ``typing-extensions``
##   4.15.0, ``importlib-metadata`` 8.7.0 and ``zipp`` 3.23.0. A wheel is a zip
##   archive (https://packaging.python.org/en/latest/specifications/binary-distribution-format/),
##   so the closure manifest
##   ``closures/python3-opentelemetry-1.34.0-windows.manifest`` unpacks each one
##   unchanged, with no installer, into its own ``site/<distribution>/``.
##   Its package directories and its ``.dist-info`` both land there;
##   ``opentelemetry-api`` reads the ``.dist-info`` entry points at import time
##   to pick its context implementation.
##
## * **The search path.** The embeddable distribution ignores ``PYTHONPATH``
##   and ``site-packages``: its ``python312._pth`` file is the whole module
##   search path (https://docs.python.org/3/library/sys_path_init.html#pth-files),
##   and as shipped it names only ``python312.zip`` (the standard library) and
##   ``.``. A closure entry cannot add to it, because each entry unpacks into a
##   directory of its own. So the arms rewrite that file with one ``preInstall``
##   ``set-content`` that keeps the two shipped entries and adds the six
##   ``site/<distribution>`` directories, relative to the file as the format
##   specifies. ``opentelemetry`` is a namespace package (PEP 420) spread over
##   three of those directories, which the import system joins.
##
## The ``._pth`` text and the manifest's destinations are generated from one
## list, ``PythonOpenTelemetryWheelDirs``, so they cannot name different
## directories.
##
## ### Refreshing
##
## Move the Windows wheels with the nixpkgs pin: take the SDK version that pin
## carries, resolve its ``requires_dist`` closure on PyPI, and record each
## wheel's URL and the sha256 PyPI publishes for it (check it against the
## download). A new CPython minor renames ``python312._pth`` and
## ``python312.zip``.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema

const
  PythonOpenTelemetryVersion* = "1.34.0"
    ## The ``opentelemetry-sdk`` version both realizations provide.
  PythonEmbedVersion* = "3.12.10"
    ## The embeddable CPython the Windows arms realize.
  PythonEmbedAmd64Sha256* =
    "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"
    ## ``python-3.12.10-embed-amd64.zip``; equal to ``packages/python3.nim``'s
    ## pin, and re-measured over the download 2026-11-20.
  PythonEmbedArm64Sha256* =
    "3065efc3d382d1cda66757ac71ade11904fa6e350f5a97eb74811acd71ba5532"
    ## ``python-3.12.10-embed-arm64.zip``, measured over the download
    ## 2026-11-20.
  PythonOpenTelemetryWindowsClosureManifest* =
    "closures/python3-opentelemetry-1.34.0-windows.manifest"
    ## The six wheels, relative to this module's directory (module doc).
  PythonOpenTelemetryWheelDirs* = [
    "site/opentelemetry_sdk",
    "site/opentelemetry_api",
    "site/opentelemetry_semantic_conventions",
    "site/typing_extensions",
    "site/importlib_metadata",
    "site/zipp",
  ]
    ## Where the closure manifest unpacks each wheel, in manifest order.
  PythonEmbedPthFile* = "python312._pth"
    ## The embeddable distribution's search-path file (module doc).

func pythonOpenTelemetryPth*(): string =
  ## The ``python312._pth`` the Windows arms write: the two entries the
  ## embeddable distribution ships (``python312.zip``, the standard library,
  ## and ``.``, the interpreter's directory), then one line per wheel
  ## directory. Each line is a path relative to the file's directory. The
  ## shipped file's ``#import site`` stays absent, so ``site`` is still not
  ## imported, as in the shipped distribution.
  result = "python312.zip\n.\n"
  for dir in PythonOpenTelemetryWheelDirs:
    result.add(dir & "\n")

const PythonOpenTelemetryPthAction =
  preInstallAction("set-content", "", "$dir/" & PythonEmbedPthFile, false,
    pythonOpenTelemetryPth())
  ## The one pre-install step of both Windows arms.

package `python3-opentelemetry`:
  provisioning:
    nixPackage "reprobuild-stdlib-python3-opentelemetry-1.34.0",
      executablePath = "bin/python3",
      expressionFile = "nix/python3-opentelemetry-1.34.0/default.nix",
      lockIdentity = "nix:python3-opentelemetry@1.34.0:opentelemetry-sdk"
    # Windows x86_64: the embeddable CPython, the six wheels, and the
    # rewritten search path (module doc).
    tarball url = "https://www.python.org/ftp/python/" & PythonEmbedVersion &
        "/python-" & PythonEmbedVersion & "-embed-amd64.zip",
      sha256 = PythonEmbedAmd64Sha256,
      archiveType = "zip",
      executablePath = "python.exe",
      # The embeddable distribution has no ``python3``; every caller says
      # ``python3`` (``packages/python3.nim`` explains the alias).
      executableAlias = "python3.exe",
      closureManifest = PythonOpenTelemetryWindowsClosureManifest,
      preInstall = PythonOpenTelemetryPthAction,
      version = PythonOpenTelemetryVersion,
      packageId = "python3-opentelemetry@" & PythonOpenTelemetryVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:python3-opentelemetry@" &
        PythonOpenTelemetryVersion & ":windows-x86_64:sha256:" &
        PythonEmbedAmd64Sha256
    # Windows aarch64: the arm64 embeddable build, with the same wheels (they
    # are pure Python) and the same search path.
    tarball url = "https://www.python.org/ftp/python/" & PythonEmbedVersion &
        "/python-" & PythonEmbedVersion & "-embed-arm64.zip",
      sha256 = PythonEmbedArm64Sha256,
      archiveType = "zip",
      executablePath = "python.exe",
      executableAlias = "python3.exe",
      closureManifest = PythonOpenTelemetryWindowsClosureManifest,
      preInstall = PythonOpenTelemetryPthAction,
      version = PythonOpenTelemetryVersion,
      packageId = "python3-opentelemetry@" & PythonOpenTelemetryVersion,
      cpu = "aarch64",
      os = "windows",
      lockIdentity = "tarball:python3-opentelemetry@" &
        PythonOpenTelemetryVersion & ":windows-aarch64:sha256:" &
        PythonEmbedArm64Sha256
