# The flake check `lib-reference`: the user reference page of the Nix helper
# library (docs/users/content/reference/nix-library.md) describes the library
# this flake exports and the options of `homeManagerModules.intent`.
#
# What is compared:
#
#   * Functions and values. Every public attribute of `reprobuild.lib`, with
#     nested attribute sets (such as `predicates`) expanded, has a
#     `### \`reprobuild.lib.<path>\`` heading, and every such heading names
#     one. `internal` is not public. Headings inside code fences do not count.
#   * Signatures. For a function that takes an attribute set, the first
#     ```nix block under its heading must name exactly the arguments
#     `builtins.functionArgs` reports, with `?` on exactly the ones that have
#     defaults. A function with positional arguments must not show a braced
#     argument set. The prose under each heading is written by hand and is
#     not compared.
#   * Realization sources. The bullets of the page's `#### Realization
#     sources` subsection, each `{ <kind> = <…>; [attribute ? null;] }`,
#     must name exactly the kinds `resolveRealizationSource` knows, and show
#     `attribute` on exactly the kinds that accept one. The kinds are read
#     from the library's own refusal of an empty source; whether a kind takes
#     `attribute` is decided by resolving a probe source with one.
#   * Module options. The region between
#     `<!-- generated:begin nix-library-options -->` and
#     `<!-- generated:end -->` must equal `render`, produced from the module's
#     own declarations (name, description, type, declared default, read-only)
#     by `lib.optionAttrSetToDocList`. Options marked `internal` or invisible
#     are left out, as Nix's own option manuals leave them out.
#
# The check also runs itself against the page with one option's block
# deleted and requires that to fail, so a checker that accepts anything
# cannot pass.
#
# Decided at evaluation time, like `lib-tests`.
{
  lib,
  reprobuildLib,
  intentOptions,
  pageText,
}:
let
  inherit (builtins)
    attrNames
    concatLists
    concatStringsSep
    elemAt
    filter
    functionArgs
    head
    isAttrs
    isFunction
    isString
    length
    listToAttrs
    match
    sort
    split
    ;

  beginMarker = "<!-- generated:begin nix-library-options -->";
  endMarker = "<!-- generated:end -->";

  # ── What the library exports ────────────────────────────────────────────
  # Every public attribute path, nested attribute sets expanded.
  publicPaths =
    prefix: set:
    concatLists (
      map (
        n:
        let
          v = set.${n};
          path = "${prefix}.${n}";
        in
        if n == "internal" then
          [ ]
        else if isAttrs v && !(lib.isDerivation v) then
          publicPaths path v
        else
          [
            {
              name = path;
              value = v;
            }
          ]
      ) (attrNames set)
    );
  libraryEntries = listToAttrs (publicPaths "reprobuild.lib" reprobuildLib);
  libraryNames = sort (a: b: a < b) (attrNames libraryEntries);

  # ── Module options, rendered ────────────────────────────────────────────
  moduleOptions = filter (
    o:
    (o.visible or true) == true
    && !(o.internal or false)
    && !(lib.hasInfix "._module." o.name)
    # A category container (`packages`, `files`, …) holds only its `enable`
    # option and has no description of its own; its `enable` is rendered.
    && !((o.type or "") == "submodule" && (o.description or null) == null)
  ) (lib.optionAttrSetToDocList intentOptions);

  textOf =
    v:
    if isAttrs v then
      v.text or ""
    else if v == null then
      ""
    else
      toString v;

  renderOption =
    o:
    let
      description = lib.trim (textOf (o.description or null));
      # Show a default only for an option a user sets: a read-only output's
      # value is computed by the module, whatever optionAttrSetToDocList
      # reports for it.
      hasDefault = (o ? default) && !(o.readOnly or false);
      default = if hasDefault then textOf o.default else "";
      # A default written as Markdown (`lib.literalMD`) is prose and may hold
      # code spans of its own; a Nix expression is shown as code.
      defaultIsProse = hasDefault && (o.default._type or "") == "literalMD";
      fields = [
        "- Type: ${o.type or "unspecified"}"
      ]
      ++ lib.optional (default != "") (
        if defaultIsProse then "- Default: ${default}" else "- Default: `${default}`"
      )
      ++ lib.optional (o.readOnly or false) "- Read-only: set by the module";
    in
    concatStringsSep "\n" (
      [
        "### `${o.name}`"
        ""
      ]
      ++ lib.optionals (description != "") [
        description
        ""
      ]
      ++ fields
    );

  render = concatStringsSep "\n\n" (map renderOption moduleOptions);

  # ── Realization sources, as the library resolves them ───────────────────
  probeDrv = {
    type = "derivation";
    name = "probe";
  };
  resolve = source: reprobuildLib.resolveRealizationSource {
    name = "probe";
    inherit source;
  };
  # `{ kind = acceptsAttribute; }`, or null when the library has no
  # realization sources.
  librarySourceKinds =
    if !(reprobuildLib ? resolveRealizationSource) then
      null
    else
      let
        reason = (resolve { }).reason or "";
        listed = match ".*exactly one of (.*) \\(it gives.*" reason;
        kinds =
          if listed == null then
            [ ]
          else
            map head (filter (x: !isString x) (split "`([a-z]+)`" (head listed)));
        found = source: (resolve source).found or false;
        acceptsAttribute =
          k:
          found {
            ${k} = { probe = probeDrv; };
            attribute = "probe";
          }
          || found {
            ${k} = probeDrv;
            attribute = "probe";
          };
      in
      listToAttrs (
        map (k: {
          name = k;
          value = acceptsAttribute k;
        }) kinds
      );

  # The same, from the page's bullets.
  documentedSourceKinds =
    text:
    let
      afterHeading = lib.splitString "#### Realization sources" text;
      # The subsection's lines, up to the next heading.
      allLines =
        if length afterHeading < 2 then [ ] else lib.drop 1 (lib.splitString "\n" (elemAt afterHeading 1));
      end = lib.lists.findFirstIndex (l: lib.hasPrefix "#" l) (length allLines) allLines;
      lines = lib.take end allLines;
      bullet = l: match "- `\\{ ([a-z]+) = <[^>]*>;( attribute \\? null;)? }`.*" l;
      bullets = filter (m: m != null) (map bullet lines);
      kinds = map head bullets;
    in
    if length afterHeading < 2 then
      null
    else if length (lib.unique kinds) != length kinds then
      { duplicate = true; }
    else
      listToAttrs (
        map (m: {
          name = head m;
          value = elemAt m 1 != null;
        }) bullets
      );

  # ── Reading a page ──────────────────────────────────────────────────────
  # The page's `### \`…\`` headings outside code fences, each with the lines
  # that follow it until the next such heading.
  sectionsOf =
    text:
    let
      step =
        acc: line:
        let
          isFence = lib.hasPrefix "```" line;
          heading = if !acc.inFence && !isFence then match "### `([^`]+)`.*" line else null;
          inFence = if isFence then !acc.inFence else acc.inFence;
        in
        if heading != null then
          {
            inFence = false;
            sections = acc.sections ++ [
              {
                name = head heading;
                body = [ ];
              }
            ];
          }
        else if acc.sections == [ ] then
          acc // { inherit inFence; }
        else
          let
            last = lib.last acc.sections;
          in
          {
            inherit inFence;
            sections = lib.init acc.sections ++ [ (last // { body = last.body ++ [ line ]; }) ];
          };
    in
    (lib.foldl' step {
      inFence = false;
      sections = [ ];
    } (lib.splitString "\n" text)).sections;

  # The text of the first ```nix block in a section, or null.
  firstNixBlock =
    body:
    let
      start = lib.lists.findFirstIndex (l: l == "```nix") null body;
      rest = if start == null then [ ] else lib.drop (start + 1) body;
      stop = lib.lists.findFirstIndex (l: lib.hasPrefix "```" l) null rest;
    in
    if start == null || stop == null then null else concatStringsSep " " (lib.take stop rest);

  # `{ name = hasDefault; }` from a documented signature, or null when it
  # shows no braced argument set.
  documentedArgs =
    signature:
    let
      # Drop interpolations (`"${homeDirectory}/…"`) so their braces do not
      # read as argument sets.
      plain = concatStringsSep "" (filter isString (split "\\$\\{[^}]*}" signature));
      braced = match "[^{]*\\{(.*)}[^}]*" plain;
      parts = if braced == null then null else map lib.trim (lib.splitString "," (head braced));
      argOf =
        part:
        let
          m = match "([A-Za-z_][A-Za-z0-9_']*)[[:space:]]*(\\?.*)?" part;
        in
        if m == null then
          null
        else
          {
            name = head m;
            value = elemAt m 1 != null;
          };
    in
    if parts == null then null else listToAttrs (filter (a: a != null) (map argOf parts));

  check =
    text:
    let
      sections = sectionsOf text;
      documented = filter (s: lib.hasPrefix "reprobuild.lib." s.name) sections;
      documentedNames = sort (a: b: a < b) (map (s: s.name) documented);
      missing = lib.subtractLists documentedNames libraryNames;
      unknown = lib.subtractLists libraryNames documentedNames;

      signatureProblems = concatLists (
        map (
          s:
          let
            value = libraryEntries.${s.name} or null;
            block = firstNixBlock s.body;
            actual = functionArgs value;
            shown = if block == null then null else documentedArgs block;
          in
          if !(isFunction value) then
            [ ]
          else if block == null then
            [ "${s.name}: no ```nix signature block" ]
          else if actual == { } && shown != null then
            [ "${s.name}: takes positional arguments, but the page shows an argument set" ]
          else if actual != { } && shown != actual then
            [
              "${s.name}: the page shows ${builtins.toJSON shown}, the function takes ${builtins.toJSON actual} (true = has a default)"
            ]
          else
            [ ]
        ) documented
      );

      afterBegin = lib.splitString beginMarker text;
      region =
        if length afterBegin != 2 then
          null
        else
          lib.trim (head (lib.splitString endMarker (elemAt afterBegin 1)));
      regionOptions = if region == null then [ ] else map (s: s.name) (sectionsOf region);
      renderedOptions = map (o: o.name) moduleOptions;
    in
    (
      let
        lib' = librarySourceKinds;
        page = documentedSourceKinds text;
      in
      if lib' == null then
        [ ]
      else if lib' == { } then
        [ "could not read the realization source kinds from resolveRealizationSource's refusal of an empty source" ]
      else if page == null then
        [ "the page has no `#### Realization sources` subsection" ]
      else if page ? duplicate then
        [ "the `#### Realization sources` subsection lists a kind of source twice" ]
      else
        lib.optional (page != lib') "the realization source shapes on the page (${builtins.toJSON page}) differ from the library's (${builtins.toJSON lib'}; true = accepts `attribute`)"
    )
    ++ map (n: "the library exports ${n} and the page does not document it") missing
    ++ map (n: "the page documents ${n}, which the library does not export") unknown
    ++ signatureProblems
    ++ lib.optional (region == null) "the page has no single `${beginMarker}` region"
    ++ map (n: "the module declares ${n} and the options region lacks it") (
      lib.subtractLists regionOptions renderedOptions
    )
    ++ map (n: "the options region shows ${n}, which the module does not declare") (
      lib.subtractLists renderedOptions regionOptions
    )
    ++ lib.optional (
      region != null && region != render
    ) "the options region differs from the module's declarations; regenerate it with `nix eval --raw .#checks.<system>.lib-reference.render`";

  # The control: the real page with one option deleted. The second option is
  # used because its block is preceded by the blank line that separates it
  # from the first, so deleting "\n\n" + its rendering removes it cleanly.
  removedOption = elemAt moduleOptions 1;
  mutatedText = builtins.replaceStrings [ ("\n\n" + renderOption removedOption) ] [ "" ] pageText;
in
{
  failures = check pageText;
  # Empty when the deletion did not change the page (the page does not carry
  # that option's block), which the flake check treats as a failure.
  controlFailures = if mutatedText == pageText then [ ] else check mutatedText;
  # A second control for the realization-source comparison: the `packages`
  # bullet without `attribute`. Empty when the page has no such bullet.
  sourceControlFailures =
    let
      mutated = builtins.replaceStrings [ "- `{ packages = <package set>; attribute ? null; }`" ] [
        "- `{ packages = <package set>; }`"
      ] pageText;
    in
    if !(reprobuildLib ? resolveRealizationSource) || mutated == pageText then [ ] else check mutated;
  inherit libraryNames render;
  controlOption = removedOption.name;
}
