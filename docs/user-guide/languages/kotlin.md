# Kotlin

Reprobuild's Kotlin support is **Mode 2 only**: existing
`build.gradle.kts` + `settings.gradle.kts` are recognized and
reprobuild shells out to `gradle build`.

## Modes available

- **Mode 2 (Gradle)**: existing `build.gradle.kts` triggers the
  `kotlin-gradle` convention.
- **Mode 3**: **not supported**. Deferred — Kotlin shares the
  JVM-ecosystem manifest requirement with Java.
- **Mode 1**: **not meaningful**.

## Quickstart (Mode 2 + Gradle)

Layout:

```text
my-kotlin-pkg/
  reprobuild.nim
  settings.gradle.kts
  build.gradle.kts
  src/
    main/
      kotlin/
        Hello.kt
```

Minimal `reprobuild.nim`:

```nim
import repro_project_dsl

package my_kotlin_pkg:
  uses:
    "java >=21"
    "gradle >=8"
  executable hello:
    discard
```

Minimal `build.gradle.kts`:

```kotlin
plugins {
    kotlin("jvm") version "1.9.20"
    application
}

application {
    mainClass.set("HelloKt")
}
```

Minimal `settings.gradle.kts`:

```kotlin
rootProject.name = "hello"
```

Build:

```text
repro build
```

The convention runs `gradle build --offline -q` and the resulting
JAR lands under `build/libs/`.

Reference fixture:
[`reprobuild-examples/kotlin-gradle/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/kotlin-gradle/hello-binary).

## Offline mode

Gradle is invoked with `--offline`. This requires that the Gradle
distribution and dependency JARs are already cached. On a fresh host,
prime the cache once by running `gradle build` without the offline
flag.

## Toolchain

Required on `PATH`:

- `gradle` (Gradle 8.x recommended).
- `javac` (JDK 21 LTS).

The Kotlin compiler `kotlinc` is bundled with the Gradle Kotlin
plugin downloaded by Gradle itself; you do NOT need a separate
`kotlinc` install.

The M9 harness SKIPs cleanly if either tool is missing.

## Dev-shell cost

- JDK ~400 MB (shared with Java).
- Gradle ~120 MB.
- First-build Kotlin plugin download adds another ~150 MB to the
  Gradle cache.

## Outstanding limitations

- **No Mode 3 Kotlin.** Hand-write `build.gradle.kts`.
- **No introspection lift.** Coarse action graph: one
  `gradle build` per package.
- **Multi-project Gradle builds** (with `include(":sub")` in
  `settings.gradle.kts`) work but reprobuild treats the whole tree as
  one opaque action.
- **Kotlin/Native (KMP non-JVM targets) NOT supported.** Mode 2 here
  is JVM-only.
- **No `.gradle.kts` introspection.** Reprobuild doesn't read the
  Gradle file at all — it only knows the package exists and invokes
  `gradle build`.

## See also

- [Language-Conventions/Kotlin.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Kotlin.md)
- [java.md](java.md) — Java + Maven, sibling JVM convention.
