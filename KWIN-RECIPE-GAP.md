# KWin From-Source Gap Report

**Generated: 2026-06-21 (M9.R.15o weekend closeout).**

`recipes/packages/source/kwin/repro.nim` declares 21 top-level deps + 3 native
build tools. **Every top-level dep has a recipe**, but several recipes —
including 5 that block the kwin link — are NOT YET PUBLISHED in the local
from-source cache and have unfetched prereqs of their own.

This report enumerates each unpublished dep, lists its blocking prereqs, and
prioritises the next M9.R.15p+ campaign.

## Cache snapshot

**57 recipes publish in the local cache (`recipes/packages/source/*/.repro/
output/install/usr`).** That covers the entire X11/Wayland/glib/cairo/pango
foundation, the full Qt6 set we're shipping (qt6-base + qt6-tools +
qt6-declarative + qt6-shadertools + qt6-svg), 23 KF6 modules through kxmlgui,
and the runtime/system layer (libdrm + libinput + libxkbcommon + mesa + pam +
sqlite + util-linux + wayland + sway + wlroots).

**KF6 unpublished**: kded, kglobalaccel, ki18n, ksolid (NOTE: these are
published per the directory listing — re-read shows ki18n/kded/kglobalaccel/
ksolid all under `.repro/output/install/usr`), kguiaddons, ksvg, kio,
knotifications, kwindowsystem, plasma-framework. The actually-unpublished set
on disk is: **ksvg, kio, knotifications, kwindowsystem, plasma-framework**.

## kwin direct deps — published vs blocked

| Dep                  | Recipe? | Published? | Blocking gap |
|----------------------|---------|------------|--------------|
| extra-cmake-modules  | yes     | yes        | -            |
| kconfig              | yes     | yes        | -            |
| kcoreaddons          | yes     | yes        | -            |
| kded                 | yes     | yes        | -            |
| kglobalaccel         | yes     | yes        | -            |
| ki18n                | yes     | yes        | -            |
| kio                  | yes     | NO         | qt6-wayland (Qt6WaylandClient) |
| knotifications       | yes     | NO         | libcanberra (libltdl + `file`) |
| kservice             | yes     | yes        | -            |
| ksolid               | yes     | yes        | -            |
| ksvg                 | yes     | NO         | kirigami (KirigamiPlatform) |
| kwidgetsaddons       | yes     | yes        | -            |
| kxmlgui              | yes     | yes        | -            |
| libdrm               | yes     | yes        | -            |
| libinput             | yes     | yes        | -            |
| libxkbcommon         | yes     | yes        | -            |
| pixman               | yes     | yes        | -            |
| plasma-framework     | yes     | NO         | knotifications (transitive) |
| qt6-base             | yes     | yes        | -            |
| qt6-tools            | yes     | yes        | -            |
| wayland              | yes     | yes        | -            |

**5 kwin direct deps are blocked.** They cascade off 3 missing fundamentals
documented below.

## Transitive prereqs missing (blocks the unblocking)

### 1. `qt6-wayland` — NEW RECIPE NEEDED (Large)

**Used by**: kwindowsystem's `find_package(Qt6WaylandClient REQUIRED)`.
Transitively blocks kio + plasma-framework + kwin.

**No recipe and no stdlib stub exist.** Upstream is Qt6's `qtwayland`
submodule — same shape as `qt6-base` / `qt6-tools` / `qt6-declarative`
(CMake-based, multi-component install). The recipe would mirror the
M9.R.15n.2 `qt6-shadertools` precedent: identical fetch + cmake_package +
artifact declarations, swap the tarball URL/sha256.

**Complexity**: Large. ~6-8 hour milestone (M9.R.15p.1): write the recipe,
fetch the tarball, debug whatever transitive Qt6 component the cmake config
discovers needs (likely Qt6Quick + Qt6ShaderTools — both already published).

**Priority**: 1 — unblocks 3 of 5 blocked kwin deps (kio + plasma-framework
+ kwin itself).

### 2. `kirigami` — NEW RECIPE NEEDED (Medium)

**Used by**: ksvg's `find_package(KF6 ... KirigamiPlatform)`. Transitively
blocks plasma-framework (via plasma's QML modules) and kwin (via ksvg).

**No recipe and no stdlib stub exist.** Upstream is KDE's `kirigami` KF6
module — same shape as kpackage / kxmlgui (CMake + qml-modules). The recipe
would clone the M9.R.15n.3 (kcrash) precedent: extra-cmake-modules native
dep + qt6-base + qt6-declarative + qt6-svg buildDeps, plus the
M9.R.15n.3/o.2 libxkbcommon + mesa Qt6Gui-transitive boilerplate.

**Complexity**: Medium. ~3-4 hour milestone (M9.R.15p.2): write the recipe,
fetch the tarball, deal with the qml-module install layout.

**Priority**: 2 — unblocks ksvg + plasma-framework's transitive surface.

### 3. `libcanberra` configure-fail — RECIPE EXISTS, FAILS TO BUILD (Small)

**Used by**: knotifications's sound-event dispatcher.

**Recipe exists at `recipes/packages/source/libcanberra/repro.nim`** but
the configure step fails with two errors:

1. `/usr/bin/file: No such file or directory` — the configure script
   shells out to `file(1)` (the unix utility) which isn't on the action's
   sandboxed PATH.
2. `Unable to find libltdl` — libcanberra needs libtool's runtime libdl
   wrapper (libltdl). The current libtool stdlib stub provides the
   build-time tool only; libltdl as a link library needs separate
   provisioning.

**Fix**:

* Add `file` to libcanberra's `nativeBuildDeps` (or — preferably — to the
  autotools_package constructor as an auto-injected always-on native dep,
  since virtually every autotools `configure` shells out to it).
* Either add a `libltdl` stdlib stub pointing at `nixpkgs#libtool.lib` or
  inline it as a libcanberra-specific buildDep.

**Complexity**: Small. ~1-2 hour milestone (M9.R.15p.3).

**Priority**: 3 — unblocks knotifications → plasma-framework.

## Recommended M9.R.15p+ dispatch order

1. **M9.R.15p.1**: write `recipes/packages/source/qt6-wayland/repro.nim`.
   Mirrors `qt6-shadertools` (M9.R.15n.2). Once landed, dispatch
   kwindowsystem → kio → plasma-framework's kwindowsystem leg.
2. **M9.R.15p.2**: write `recipes/packages/source/kirigami/repro.nim`.
   Mirrors `kpackage`'s shape + the M9.R.15o.2 libxkbcommon+mesa
   annotation. Once landed, dispatch ksvg.
3. **M9.R.15p.3**: libcanberra fix — add `file` + libltdl. Once landed,
   dispatch knotifications → plasma-framework's notifications leg.
4. **M9.R.15p.4**: re-attempt plasma-framework (should publish now).
5. **M9.R.15p.5**: re-attempt kwin (all direct deps published).

**Estimated total for the kwin link-up**: 12-18 hours, single-weekend
scope feasible.

## Constructor-level boilerplate retirement

M9.R.15n.3..5 + M9.R.15o.2/3/4 added identical `libxkbcommon` + `mesa`
buildDeps annotations to 6 recipes. The M9.R.15o.1 helpers
(`m9r15oCollectQt6TransitiveCmakeDeps` +
`m9r15oCollectQt6TransitiveCmakeConfigDirs` in
`libs/repro_dsl_stdlib/src/repro_dsl_stdlib/types/package_result.nim`)
handle the **cacheVars** side of the auto-thread (Qt6Quick_DIR etc.) but
the **search-path channel** side (PKG_CONFIG_PATH / CMAKE_PREFIX_PATH for
the actual libraries libxkbcommon.so / libGLESv2.so) requires the deps to
be declared as tool-uses at macro-expansion time, not virtually injected
at provider runtime.

The architectural fix is to inject the auto-deps at the **package macro**
level (`libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim`,
around line 1487 where `pkg.toolUses` is concatenated for the
projectInterface). That's a 2-4 hour milestone (M9.R.15p.0) and should
be done before M9.R.15p.1 so qt6-wayland / kirigami / future Qt6Gui
consumers get the libxkbcommon + mesa side automatically.
