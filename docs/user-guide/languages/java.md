# Java

Reprobuild's Java support is **Mode 2 only**: existing `pom.xml`
(Maven) is recognized and reprobuild shells out to `mvn package`.
There is no Java Mode 3 today — the JVM ecosystem's per-package
dependency tracking, classpath construction, and resource bundling
are non-trivial to reimplement.

## Modes available

- **Mode 2 (Maven)**: existing `pom.xml` triggers the `java-maven`
  convention.
- **Mode 3**: **not supported**. Deferred — the JVM ecosystem's
  classpath / dependency model would need a dedicated convention.
- **Mode 1**: **not meaningful** for Java (the language requires a
  manifest for dependency declaration).

## Quickstart (Mode 2 + Maven)

Layout:

```text
my-java-pkg/
  reprobuild.nim
  pom.xml
  src/
    main/
      java/
        com/
          example/
            Hello.java
```

Minimal `reprobuild.nim`:

```nim
import repro_project_dsl

package my_java_pkg:
  uses:
    "java >=21"
    "mvn >=3.9"
  executable hello:
    discard
```

Minimal `pom.xml`:

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>hello</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
  <properties>
    <maven.compiler.source>21</maven.compiler.source>
    <maven.compiler.target>21</maven.compiler.target>
  </properties>
</project>
```

Build:

```text
repro build
```

The convention runs `mvn package -o -q` from the package root and the
output JAR lands under `target/hello-1.0.jar`.

Reference fixture:
[`reprobuild-examples/java-maven/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/java-maven/hello-binary).

## Offline mode

The convention invokes Maven with `-o` (offline). This requires that
the Maven plugin jars are already cached in `~/.m2/repository/`. On a
fresh host, prime the cache once with:

```text
mvn dependency:go-offline -f pom.xml
```

After that, every reprobuild invocation runs fully offline. The
intent is reproducible builds without surprise network access.

## Toolchain

Required on `PATH`:

- `mvn` (Apache Maven 3.9.x recommended).
- `javac` (Adoptium JDK 21 LTS recommended; any JDK with a `javac`
  that can target the pom's `maven.compiler.source` /
  `maven.compiler.target` will do).

The M9 harness SKIPs cleanly if either is missing.

Supported install paths on Windows (env.ps1 will eventually wire these
up):

- Adoptium JDK 21 LTS → `D:/metacraft-dev-deps/jdk/21/`
- Apache Maven 3.9.x → `D:/metacraft-dev-deps/maven/3.9.x/`

env.ps1 should prepend `<jdk>/bin` + `<maven>/bin` to `PATH`.

## Dev-shell cost

The JDK is ~400 MB. Maven itself is ~10 MB but downloads more on first
use. Be aware before adding Java to your reprobuild workflow.

## Outstanding limitations

- **No Mode 3 Java.** Hand-write `pom.xml`.
- **No introspection lift.** The action graph is coarse: one
  `mvn package` per workspace package, opaque to the action cache.
  Incremental Maven rebuilds happen at Maven's internal cache level,
  not reprobuild's.
- **Gradle is separate.** See [`kotlin.md`](kotlin.md) for the
  Kotlin/Gradle convention — also usable for Java/Gradle if you
  prefer.
- **No multi-module Maven workspace.** One pom.xml per `package`
  block; nested module hierarchies would need a `build:` block.
- **No JPMS / `module-info.java` introspection.**

## See also

- [Language-Conventions/Java.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Java.md)
- [kotlin.md](kotlin.md) — Kotlin + Gradle, also Java-capable.
