type
  HcrReferenceEntry* = object
    id*: string
    family*: string
    availabilityMode*: string
    localCheckout*: string
    upstreamUrl*: string
    pinnedCommit*: string
    sourcePaths*: seq[string]
    documentationPaths*: seq[string]
    docUrls*: seq[string]
    docsAccessDate*: string
    docsProvenance*: string
    algorithmAreas*: seq[string]
    hcrSpecSections*: seq[string]

  HcrReferenceCorpus* = object
    schemaId*: string
    entries*: seq[HcrReferenceEntry]

  DirectHcrGateMetadata* = object
    schemaId*: string
    milestone*: string
    positivePath*: string
    sharedLibraryLoadingPositivePath*: string
    forbiddenPositivePathApis*: seq[string]
    forbiddenBuildFlags*: seq[string]

proc hcrReferenceCorpus*(): HcrReferenceCorpus =
  HcrReferenceCorpus(
    schemaId: "reprobuild.hcr.reference-linker-corpus.v1",
    entries: @[
      HcrReferenceEntry(
        id: "mold",
        family: "high-performance-elf-linker",
        availabilityMode: "manifest-repo",
        localCheckout: "references/mold",
        upstreamUrl: "https://github.com/rui314/mold",
        pinnedCommit: "45970e661d462fd664e7249a4bfc20ca4d0c6f39",
        sourcePaths: @[
          "src/passes.cc",
          "src/input-sections.cc",
          "src/output-chunks.cc",
          "src/shrink-sections.cc",
          "src/thunks.cc",
          "src/arch-arm64.cc",
          "src/arch-x86-64.cc",
          "src/relocatable.cc"
        ],
        documentationPaths: @[
          "docs/design.md",
          "docs/glossary.md"
        ],
        docUrls: @[],
        docsAccessDate: "",
        docsProvenance: "",
        algorithmAreas: @[
          "phase-separated scan/allocation/relocation pipeline",
          "parallel relocation scanning and application",
          "GOT relaxation and section shrinking",
          "range-extension thunk planning",
          "relocatable object handling"
        ],
        hcrSpecSections: @[
          "HCR/Incremental-Linker-Algorithm.md#1-design-principles",
          "HCR/Incremental-Linker-Algorithm.md#2-data-structures",
          "HCR/Relocation-Processing.md",
          "Test-Designs/Reprobuild-HCR-Direct-Patch-Algorithm-Validation.md#reference-linker-use"
        ]),
      HcrReferenceEntry(
        id: "wild",
        family: "incremental-elf-linker",
        availabilityMode: "manifest-repo",
        localCheckout: "references/wild",
        upstreamUrl: "https://github.com/davidlattimore/wild",
        pinnedCommit: "58f3e1033a8b05ee2f8ea18f9abd8e6adacd1470",
        sourcePaths: @[
          "libwild/src/diff.rs",
          "libwild/src/layout.rs",
          "libwild/src/thunks.rs",
          "libwild/src/elf.rs",
          "libwild/src/elf_aarch64.rs",
          "libwild/src/symbol_db.rs",
          "linker-diff/src/section_map.rs",
          "linker-diff/src/symbol_diff.rs"
        ],
        documentationPaths: @[
          "DESIGN.md",
          "linker-diff/README.md",
          "libwild/MachO.md"
        ],
        docUrls: @[],
        docsAccessDate: "",
        docsProvenance: "",
        algorithmAreas: @[
          "incremental model and section/object diffing",
          "symbol database and resolution state",
          "relocation-aware layout",
          "range-extension thunk planning",
          "structural linker-diff assertions"
        ],
        hcrSpecSections: @[
          "HCR/Incremental-Linker-Algorithm.md#13-relocation-reverse-index-for-incremental-updates",
          "HCR/Binary-Diffing-And-Symbol-Resolution.md",
          "Test-Designs/Reprobuild-HCR-Direct-Patch-Algorithm-Validation.md#reference-linker-use"
        ]),
      HcrReferenceEntry(
        id: "llvm-jitlink-lld",
        family: "in-memory-linker-and-system-linker",
        availabilityMode: "manifest-repo",
        localCheckout: "references/llvm-project",
        upstreamUrl: "https://github.com/llvm/llvm-project",
        pinnedCommit: "07f6bc4883b2a0ee1f7f999b25774003b75f9bc1",
        sourcePaths: @[
          "llvm/include/llvm/ExecutionEngine/JITLink/JITLink.h",
          "llvm/lib/ExecutionEngine/JITLink/JITLink.cpp",
          "llvm/lib/ExecutionEngine/JITLink/MachOLinkGraphBuilder.cpp",
          "llvm/lib/ExecutionEngine/JITLink/MachO_arm64.cpp",
          "llvm/lib/ExecutionEngine/JITLink/ELFLinkGraphBuilder.cpp",
          "llvm/lib/ExecutionEngine/JITLink/PerGraphGOTAndPLTStubsBuilder.h",
          "lld/ELF/Relocations.cpp",
          "lld/ELF/Thunks.cpp",
          "lld/MachO/Relocations.cpp",
          "lld/MachO/ConcatOutputSection.h"
        ],
        documentationPaths: @[
          "llvm/docs/JITLink.rst",
          "llvm/docs/ORCv2.rst"
        ],
        docUrls: @[],
        docsAccessDate: "",
        docsProvenance: "",
        algorithmAreas: @[
          "LinkGraph object model",
          "in-memory object linking passes",
          "Mach-O and ELF object ingestion",
          "GOT/PLT and stub construction",
          "lld relocation and thunk corpus"
        ],
        hcrSpecSections: @[
          "HCR/Incremental-Linker-Algorithm.md#2-data-structures",
          "HCR/Relocation-Processing.md",
          "HCR/Trampoline-Mechanics.md",
          "Test-Designs/Reprobuild-HCR-Direct-Patch-Algorithm-Validation.md#fixture-shape-and-required-tools"
        ]),
      HcrReferenceEntry(
        id: "msvc-incremental",
        family: "coff-pe-incremental-linker-documentation",
        availabilityMode: "pinned-map",
        localCheckout: "",
        upstreamUrl: "https://learn.microsoft.com/en-us/cpp/build/reference/",
        pinnedCommit: "",
        sourcePaths: @[],
        documentationPaths: @[],
        docUrls: @[
          "https://learn.microsoft.com/en-us/cpp/build/reference/incremental-link-incrementally",
          "https://learn.microsoft.com/en-us/cpp/build/reference/hotpatch-create-hotpatchable-image",
          "https://learn.microsoft.com/en-us/cpp/build/reference/functionpadmin-create-hotpatchable-image"
        ],
        docsAccessDate: "2026-05-16",
        docsProvenance: "Microsoft Learn docs-only pinned map; no local checkout and no network access required by the M25 test",
        algorithmAreas: @[
          "incremental link fallback conditions",
          "hotpatchable function padding",
          "incremental-link-table and padding concepts",
          "COFF/PE support-profile constraints"
        ],
        hcrSpecSections: @[
          "HCR/Incremental-Linker-Algorithm.md#12-trampoline-based-redirection-not-thunks",
          "HCR/Trampoline-Mechanics.md",
          "HCR/Relocation-Processing.md",
          "Test-Designs/Reprobuild-HCR-Direct-Patch-Algorithm-Validation.md#platform-matrix"
        ])
    ])

proc directHcrGateMetadata*(): DirectHcrGateMetadata =
  DirectHcrGateMetadata(
    schemaId: "reprobuild.hcr.direct-gate-metadata.v1",
    milestone: "M25",
    positivePath: "direct-in-target-incremental-linker-object-inputs",
    sharedLibraryLoadingPositivePath: "forbidden",
    forbiddenPositivePathApis: @[
      "dlopen",
      "dlsym",
      "LoadLibrary",
      "GetProcAddress"
    ],
    forbiddenBuildFlags: @[
      "-shared",
      "-dynamiclib"
    ])
