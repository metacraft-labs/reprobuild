# Profile Modules — canonical M83 Phase F1 examples

This directory ships ready-to-use examples of the reprobuild
**profile module** pattern. A profile module is a sibling `.nim`
file that lives next to a `home.nim` (or `system.nim`) profile root
and exports reusable templates / procs the profile can compose.

Use these examples as starting points for authoring your own
modules. The shapes here are the same shapes the spec describes in
[`Profile-Compilation-Model.md`](../../../reprobuild-specs/Profile-Compilation-Model.md);
nothing magic happens — reprobuild's profile-compile pipeline just
asks Nim to compile the profile, and Nim's normal sibling-import
machinery resolves `import ./modules/git_dev_environment`.

## What's in here

- `home-with-modules/` — a working example profile directory you can
  point `repro home apply` at. Contains:
  - `home.nim` — the profile root. Imports two sibling modules and
    composes them into activities + a `config:` block.
  - `modules/git_dev_environment.nim` — exports `gitDevTooling()`
    (a package-bundle helper) and `gitIdentity(name, email)` (a
    config-override helper).
  - `modules/dev_shell.nim` — exports `developerShell()`, a
    second package-bundle helper, to show that multiple modules
    compose.

## How reprobuild resolves the import

When you run `repro home apply` (or one of the lower-level commands
that calls `compileProfileToRbpi`), reprobuild:

1. **Discovers sources.** Starting from your `home.nim`, the
   profile-compile pipeline walks every `import ./...` /
   `import "./..."` line and the chain of sibling modules they
   transitively reach. Each discovered file becomes part of the
   compile's source set and digest (so touching any file in the
   closure invalidates the cache).
2. **Compiles via Nim.** The compile pipeline invokes the bundled
   Nim toolchain with the right `--path:` entries so
   `import repro_profile` resolves and your sibling imports
   resolve against your profile directory. The macros in
   `repro_profile` consume the body of `profile "...":` and emit
   the runtime that builds the `ProfileIntent` value.
3. **Encodes RBPI + caches.** The compiled binary prints a
   JSON representation of the `ProfileIntent`; the pipeline
   re-encodes that through the binary RBPI envelope and parks
   the bytes in `<state-dir>/profile-cache/<digest>.rbpi` for
   reuse on the next apply.
4. **Hands the intent to the apply pipeline.** From there the
   adapter chain (`profileIntentToHomeProfile`) feeds the
   apply pipeline the same way a hand-rolled profile would.

There is no user-facing `repro profile build` command — the
compile step is a normal build-graph edge and the apply
pipeline drives it automatically. You author profiles and run
`repro home apply` exactly as you did before; the modules just
work.

## Authoring your own module

Three rules cover the common cases:

1. **Package-bundle helpers** are procs that return
   `seq[ActivityElement]`. The activity-body parser splats the
   return value, so a single helper call inlines an arbitrary
   number of packages into the activity.

   ```nim
   proc myToolingBundle*(): seq[ActivityElement] =
     @[
       package "ripgrep",
       package "fd",
       package "jq",
     ]
   ```

2. **Resource helpers** are templates whose FIRST positional
   parameter is the in-scope `targetResources` seq. The
   `resources:` macro splices the in-scope list in for you, so the
   user-side call site spells only the meaningful arguments.

   ```nim
   template myDotfiles*(targetResources: var seq[ResourceIntent]) =
     fsUserFile(targetResources, hostFile = "~/.config/foo",
       content = "...")
   ```

3. **Config-override helpers** follow the same convention as
   resource helpers, but the first positional parameter is the
   in-scope `targetOverrides` (a `var seq[ConfigOverride]`). The
   `config:` macro splices that in. See
   `home-with-modules/modules/git_dev_environment.nim` for the
   canonical shape.

You can `import` other sibling modules from a sibling module —
the source-discovery walk is transitive — so larger profile
trees can factor out shared helpers under a deeper module
hierarchy.

## Running the example

From a clean checkout (with the dev shell active):

```pwsh
. .\env.ps1
nim c -r --path:libs/repro_profile/src \
        examples/profile-modules/home-with-modules/home.nim
```

The binary prints the JSON `ProfileIntent` on stdout. To drive
the full apply pipeline against the example, point `repro home
apply` at the directory:

```pwsh
repro home apply --profile-dir examples/profile-modules/home-with-modules
```

(use a throwaway `--state-dir` / `--home-dir` if you do not want
the apply to touch your real home directory).
