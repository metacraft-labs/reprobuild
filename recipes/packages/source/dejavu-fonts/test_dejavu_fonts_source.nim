import std/[os, unittest]

suite "DejaVu fonts source recipe":
  test "installs generated core font families":
    let root = getCurrentDir() / ".repro" / "output" / "install" /
      "usr" / "share" / "fonts" / "truetype" / "dejavu"
    check fileExists(root / "DejaVuSans.ttf")
    check fileExists(root / "DejaVuSansMono.ttf")
    check fileExists(root / "DejaVuSerif.ttf")
    check getFileSize(root / "DejaVuSans.ttf") > 100_000
