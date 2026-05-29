# Swift

Reprobuild's Swift support is **Mode 2 only**: existing `Package.swift`
is recognized and reprobuild shells out to `swift build`.

## Modes available

- **Mode 2 (SwiftPM)**: existing `Package.swift` triggers the
  `swift-swiftpm` convention.
- **Mode 3**: **not supported**. SwiftPM's manifest is itself Swift
  code that runs at configure time — there's no static form to lift.
- **Mode 1**: **not meaningful**.

## Quickstart (Mode 2 + SwiftPM)

Layout:

```text
my-swift-pkg/
  reprobuild.nim
  Package.swift
  Sources/
    hello/
      main.swift
```

Minimal `reprobuild.nim`:

```nim
import repro_project_dsl

package my_swift_pkg:
  uses:
    "swift >=5.9"
  executable hello:
    discard
```

Minimal `Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hello",
    targets: [
        .executableTarget(name: "hello", path: "Sources/hello"),
    ]
)
```

Minimal `Sources/hello/main.swift`:

```swift
print("hello from swift")
```

Build:

```text
repro build
```

The convention runs `swift build -c release --disable-automatic-resolution`
and the output binary lands under `.build/release/hello`.

Reference fixture:
[`reprobuild-examples/swift-swiftpm/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/swift-swiftpm/hello-binary).

## Offline mode

The convention passes `--disable-automatic-resolution` to require
that `Package.resolved` is up-to-date. On a fresh host, prime by
running `swift package resolve` once.

## Toolchain

Required on `PATH`:

- `swift` (Swift 5.9+ recommended).

The M9 harness SKIPs cleanly if `swift` is missing.

## Dev-shell cost

The Swift toolchain is ~600 MB on disk (largest of the JVM/.NET/Swift
trio). On macOS Swift ships with Xcode / Command Line Tools. On Linux
and Windows install from `swift.org/download`.

## Outstanding limitations

- **No Mode 3 Swift.** Hand-write `Package.swift`.
- **No introspection lift.** One opaque `swift build` per package.
- **No `Package.swift` parsing.** Reprobuild doesn't read the
  manifest — it only knows the package exists.
- **No Xcode project files** (`.xcodeproj`, `.xcworkspace`). SwiftPM
  only.
- **No iOS / watchOS / tvOS cross-compile.** Default host target only.
- **No Swift macros.** Macro packages need macro resolution which
  Mode 2's `swift build` handles, but reprobuild doesn't observe it
  at the action-graph level.

## See also

- [Language-Conventions/Swift.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Swift.md)
