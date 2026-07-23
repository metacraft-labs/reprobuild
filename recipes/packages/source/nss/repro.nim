import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package nssSource:
  versions:
    "3.107":
      sourceRevision = "NSS_3_107_RTM"
      sourceUrl = "https://archive.mozilla.org/pub/security/nss/releases/NSS_3_107_RTM/src/nss-3.107.tar.gz"
      sourceRepository = "https://hg.mozilla.org/projects/nss"
  fetch:
    url: "https://archive.mozilla.org/pub/security/nss/releases/NSS_3_107_RTM/src/nss-3.107.tar.gz"
    sha256: "7f7e96473e38150771a615f5d40e8c41ba3a19385301ae0c525091f2fc9d6729"
    extractStrip: 1
  nativeBuildDeps:
    "gcc >=11"
    "gyp"
    "ninja >=1.10"
    "python3 >=3.8"
    "pkg-config"
  buildDeps:
    "nspr >=4.36"
    "sqlite >=3.40"
    "zlib"
  config:
    discard
  library libNss3:
    build:
      shell "NSPR=/opt/repro/reprobuild/recipes/packages/source/nspr/.repro/output/install/usr; SQLITE=/opt/repro/reprobuild/recipes/packages/source/sqlite/.repro/output/install/usr; ZLIB=/opt/repro/reprobuild/recipes/packages/source/zlib/.repro/output/install/usr; export CPATH=$NSPR/include/nspr:$SQLITE/include:$ZLIB/include LIBRARY_PATH=$NSPR/lib:$SQLITE/lib:$ZLIB/lib PKG_CONFIG_PATH=$NSPR/lib/pkgconfig:$SQLITE/lib/pkgconfig:$ZLIB/lib/pkgconfig; mkdir -p dist/Release/lib; ln -sf $NSPR/lib/libnspr4.so $NSPR/lib/libplc4.so $NSPR/lib/libplds4.so dist/Release/lib/; cd nss; ./build.sh -v --opt --gcc --disable-tests --with-nspr=$NSPR/include/nspr:$NSPR/lib --system-sqlite; rm -f ../dist/Release/lib/libnspr4.so ../dist/Release/lib/libplc4.so ../dist/Release/lib/libplds4.so"
      shell "mkdir -p $out/install/usr/lib/pkgconfig $out/install/usr/include/nss; cp -a dist/Release/lib/*.so* $out/install/usr/lib/; cp -a dist/public/nss/. $out/install/usr/include/nss/; printf 'prefix=%s\\nexec_prefix=${prefix}\\nlibdir=${prefix}/lib\\nincludedir=${prefix}/include/nss\\n\\nName: NSS\\nDescription: Network Security Services\\nVersion: 3.107\\nRequires: nspr >= 4.36\\nLibs: -L${libdir} -lssl3 -lsmime3 -lnss3 -lnssutil3\\nCflags: -I${includedir}\\n' \"$out/install/usr\" > $out/install/usr/lib/pkgconfig/nss.pc"
  library libNssutil3:
    discard
  library libSmime3:
    discard
  library libSsl3:
    discard
  library libSoftokn3:
    discard
  library libFreebl3:
    discard
  runtimeDeps:
    "nspr >=4.36"
    "sqlite >=3.40"
    "zlib"
