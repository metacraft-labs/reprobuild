## Real artifact serialization and decoding, with no mocks. The small-value
## digest was measured before widening the value bound at d481a2c5 plus its
## POSIX bridge, so changing both codec directions cannot bless a wire change.
import std/[strutils, unittest]
import blake3
import repro_dev_env_artifacts
import repro_provider_runtime

proc fixture(value: string): DevEnvArtifact =
  DevEnvArtifact(projectRoot: "/fixture", shellOps: @[
    DevEnvShellOp(kind: deskSetEnv, name: "FIXTURE", value: value)])

suite "dev-env large environment values":
  test "Nix-sized values round-trip through the real SSZ envelope":
    let value = repeat(" -isystem /nix/store/dependency/include", 900)
    check value.len > 16 * 1024
    let encoded = encodeDevEnvArtifact(fixture(value))
    let decoded = decodeDevEnvArtifact(encoded)
    check decoded.shellOps.len == 1
    check decoded.shellOps[0].value == value
    check encodeDevEnvArtifact(decoded) == encoded

  test "small artifacts retain the pre-change wire bytes":
    let digest = blake3.digest(encodeDevEnvArtifact(fixture("small")))
    var hex = ""
    for b in digest: hex.add(toHex(int(b), 2).toLowerAscii())
    check hex == "5260be4bfb09c2ffe0536e5057001b866a0b478e5e5251660495d7c54be5521e"

  test "value capacity is bounded independently of metadata":
    let largest = repeat("x", 128 * 1024)
    check decodeDevEnvArtifact(encodeDevEnvArtifact(fixture(largest))).shellOps[0].value == largest
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(fixture(largest & "x"))
    var named = fixture("small")
    named.shellOps[0].name = repeat("x", 16 * 1024 + 1)
    expect DevEnvArtifactCodecError:
      discard encodeDevEnvArtifact(named)
