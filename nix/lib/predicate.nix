# The built-in predicate grammar, evaluated in Nix.
#
# Guards in a `repro home export` document and the `when` field of a plan-time
# data file use the built-in predicate grammar only: `windows`, `macos`,
# `linux`, `bsd`, `wsl`, `x86_64`, `arm64`, `arm32`, `true`, `false`,
# `host == "…"` / `!=` / `in [ … ]`, combined with `and`, `or`, `not` and
# parentheses (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md
# §Declarative data files read at plan time).
#
# This is the SECOND implementation of that grammar. The first, and the one
# that defines it, is `libs/repro_home_intent/src/repro_home_intent/predicate.nim`
# (`parsePredicate`, `validateBuiltinPredicate`, `predicateHolds`). A Nix
# evaluation cannot run Reprobuild code in snapshot mode, so the Nix boundary
# forces a second one (spec §Platform-neutral intent). What keeps the two
# from drifting is `tests/fixtures/predicates/cases.json`: the Nim test
# `t_builtin_predicate_fixtures` and this flake's `lib-tests` check read it
# unchanged. The structure below deliberately follows the Nim file function
# by function (lexer, recursive-descent parser with the same precedence,
# built-in validation, evaluator), quirks included, so a reader can compare
# them side by side.
#
# Pure: builtins only, no nixpkgs.
let
  inherit (builtins)
    elemAt
    length
    stringLength
    substring
    match
    head
    tail
    filter
    any
    all
    elem
    ;

  standardPlatformIdents = [
    "windows"
    "macos"
    "linux"
    "bsd"
    "wsl"
  ];
  standardArchIdents = [
    "x86_64"
    "arm64"
    "arm32"
  ];
  standardHostIdent = "host";

  lower =
    s:
    builtins.replaceStrings (builtins.genList (i: substring i 1 "ABCDEFGHIJKLMNOPQRSTUVWXYZ") 26) (
      builtins.genList
      (i: substring i 1 "abcdefghijklmnopqrstuvwxyz")
      26
    ) s;

  # `isStandardIdent` in predicate.nim: standard identifiers are matched
  # case-insensitively; user-defined ones keep their case.
  isStandardIdent =
    name:
    let
      l = lower name;
    in
    elem l standardPlatformIdents || elem l standardArchIdents || l == standardHostIdent;

  # ---------------------------------------------------------------------------
  # Lexer (`lex` in predicate.nim).
  # ---------------------------------------------------------------------------
  keywords = {
    "and" = "and";
    "or" = "or";
    "not" = "not";
    "in" = "in";
    "true" = "true";
    "false" = "false";
  };

  lex =
    src:
    let
      n = stringLength src;
      at = i: substring i 1 src;
      isWs = c: c == " " || c == "\t" || c == "\r" || c == "\n";
      isIdentStart = c: match "[A-Za-z_]" c != null;
      isIdentCont = c: match "[A-Za-z0-9_]" c != null;
      tok = kind: text: { inherit kind text; };
      identEnd = j: if j < n && isIdentCont (at j) then identEnd (j + 1) else j;
      # A string literal runs to the next `"`; a backslash takes the next
      # character literally. A literal with no closing quote is not a string:
      # it becomes an `unterminated` token (text: the literal as written,
      # opening quote included) that no grammar position accepts, so the
      # parser refuses it -- as predicate.nim's `tkUnterminatedStr` does.
      readString =
        j: acc:
        if j >= n then
          {
            text = acc;
            next = j;
            terminated = false;
          }
        else if at j == "\"" then
          {
            text = acc;
            next = j + 1;
            terminated = true;
          }
        else if at j == "\\" && j + 1 < n then
          readString (j + 2) (acc + at (j + 1))
        else
          readString (j + 1) (acc + at j);
      go =
        i:
        if i >= n then
          [ (tok "eof" "") ]
        else
          let
            c = at i;
          in
          if isWs c then
            go (i + 1)
          else if c == "(" then
            [ (tok "lparen" c) ] ++ go (i + 1)
          else if c == ")" then
            [ (tok "rparen" c) ] ++ go (i + 1)
          else if c == "[" then
            [ (tok "lbracket" c) ] ++ go (i + 1)
          else if c == "]" then
            [ (tok "rbracket" c) ] ++ go (i + 1)
          else if c == "," then
            [ (tok "comma" c) ] ++ go (i + 1)
          else if c == "=" && at (i + 1) == "=" then
            [ (tok "eq" "==") ] ++ go (i + 2)
          else if c == "!" && at (i + 1) == "=" then
            [ (tok "ne" "!=") ] ++ go (i + 2)
          else if c == "\"" then
            let
              s = readString (i + 1) "";
            in
            if s.terminated then
              [ (tok "str" s.text) ] ++ go s.next
            else
              [ (tok "unterminated" (substring i (n - i) src)) ] ++ go s.next
          else if isIdentStart c then
            let
              j = identEnd (i + 1);
              id = substring i (j - i) src;
            in
            [ (tok (keywords.${id} or "ident") id) ] ++ go j
          else
            # An unknown character becomes a one-character identifier, so the
            # validator names it (as predicate.nim does).
            [ (tok "ident" c) ] ++ go (i + 1);
    in
    go 0;

  # ---------------------------------------------------------------------------
  # Parser (`parsePredicate`). Every function takes a token position and
  # returns `{ node; pos; }`, or `{ error; }` -- a value, not a `throw`, so
  # callers can report the diagnostic (`builtins.tryEval` discards messages).
  # Precedence, loosest first: or, and, not, comparison, atom.
  # ---------------------------------------------------------------------------
  parse =
    src:
    let
      toks = lex src;
      last = length toks - 1;
      tk = p: elemAt toks p;
      adv = p: if p < last then p + 1 else p;
      ok = node: pos: { inherit node pos; };
      unexpected = t: expected: {
        error = "unexpected '${t.text}': expected ${expected}";
      };
      failed = r: r ? error;

      parseList =
        p:
        let
          p1 = adv p; # past `[`
        in
        if (tk p1).kind == "rbracket" then
          ok {
            kind = "list";
            items = [ ];
          } (adv p1)
        else
          listItems p1 [ ];
      listItems =
        p: items:
        let
          r = parseAtom p;
        in
        if failed r then
          r
        else
          let
            items' = items ++ [ r.node ];
            t = tk r.pos;
          in
          if t.kind == "comma" then
            listItems (adv r.pos) items'
          else if t.kind == "rbracket" then
            ok {
              kind = "list";
              items = items';
            } (adv r.pos)
          else
            unexpected t "']'";

      parseAtom =
        p:
        let
          t = tk p;
        in
        if t.kind == "true" || t.kind == "false" then
          ok {
            kind = "bool";
            value = t.kind == "true";
          } (adv p)
        else if t.kind == "str" then
          ok {
            kind = "str";
            value = t.text;
          } (adv p)
        else if t.kind == "ident" then
          let
            p1 = adv p;
            node = {
              kind = "ident";
              name = t.text;
            };
          in
          # The call form `linux()` is the bare identifier.
          if (tk p1).kind == "lparen" then
            let
              p2 = adv p1;
            in
            if (tk p2).kind == "rparen" then
              ok node (adv p2)
            else
              unexpected (tk p2) "an empty argument list `()` after the predicate identifier"
          else
            ok node p1
        else if t.kind == "lparen" then
          let
            r = parseOr (adv p);
          in
          if failed r then
            r
          else if (tk r.pos).kind == "rparen" then
            ok r.node (adv r.pos)
          else
            unexpected (tk r.pos) "')'"
        else if t.kind == "lbracket" then
          parseList p
        else if t.kind == "unterminated" then
          {
            error = "saw the unterminated string literal ${t.text}; expected a closing '\"'";
          }
        else
          unexpected t "an identifier, string literal, '(' expression, '[' list, true, or false";

      parseComparison =
        p:
        let
          l = parseAtom p;
          t = if failed l then null else tk l.pos;
          ops = {
            eq = "eq";
            ne = "ne";
            "in" = "in";
          };
        in
        if failed l then
          l
        else if ops ? ${t.kind} then
          let
            r = parseAtom (adv l.pos);
          in
          if failed r then
            r
          else
            ok {
              kind = ops.${t.kind};
              lhs = l.node;
              rhs = r.node;
            } r.pos
        else
          l;

      parseNot =
        p:
        if (tk p).kind == "not" then
          let
            r = parseNot (adv p);
          in
          if failed r then
            r
          else
            ok {
              kind = "not";
              operand = r.node;
            } r.pos
        else
          parseComparison p;

      # An n-ary chain of `op` over `sub`, as `parseAnd` / `parseOr` build it.
      chain =
        op: sub: p:
        let
          first = sub p;
          more =
            pos: acc:
            if (tk pos).kind == op then
              let
                r = sub (adv pos);
              in
              if failed r then r else more r.pos (acc ++ [ r.node ])
            else
              ok {
                kind = op;
                operands = acc;
              } pos;
        in
        if failed first then
          first
        else if (tk first.pos).kind == op then
          more first.pos [ first.node ]
        else
          first;
      parseAnd = chain "and" parseNot;
      parseOr = chain "or" parseAnd;

      top = parseOr 0;
    in
    if failed top then
      top
    else if (tk top.pos).kind != "eof" then
      unexpected (tk top.pos) "end of predicate expression"
    else
      { ast = top.node; };

  # ---------------------------------------------------------------------------
  # Built-in-only validation (`validateBuiltinPredicate`).
  # ---------------------------------------------------------------------------

  # Non-standard identifiers, in source order.
  unknownIdents =
    n:
    if n.kind == "ident" then
      (if isStandardIdent n.name then [ ] else [ n.name ])
    else if n.kind == "list" then
      builtins.concatMap unknownIdents n.items
    else if n.kind == "and" || n.kind == "or" then
      builtins.concatMap unknownIdents n.operands
    else if n.kind == "not" then
      unknownIdents n.operand
    else if n.kind == "eq" || n.kind == "ne" || n.kind == "in" then
      unknownIdents n.lhs ++ unknownIdents n.rhs
    else
      [ ];

  firstProblem = problems: if problems == [ ] then "" else head problems;
  nonEmpty = filter (p: p != "");

  # Why `n` is not a well-typed expression of the built-in grammar in a
  # position of type bool (`wantBool`) or string, or "" -- `builtinShapeProblem`.
  shapeProblem =
    n: wantBool:
    if n.kind == "bool" then
      (if wantBool then "" else "a boolean literal is not a string operand")
    else if n.kind == "ident" then
      let
        id = lower n.name;
      in
      if id == standardHostIdent then
        (if wantBool then "`host` is a string; compare it (`host == \"name\"`)" else "")
      else if elem id standardPlatformIdents || elem id standardArchIdents then
        (if wantBool then "" else "`${n.name}` is a boolean, not a string operand")
      else
        "unknown predicate identifier '${n.name}'"
    else if n.kind == "str" then
      (if wantBool then "a string literal cannot stand alone as a condition" else "")
    else if n.kind == "list" then
      "a list literal is only allowed on the right of `in`"
    else if n.kind == "and" || n.kind == "or" then
      (
        if !wantBool then
          "a boolean expression is not a string operand"
        else
          firstProblem (nonEmpty (map (op: shapeProblem op true) n.operands))
      )
    else if n.kind == "not" then
      (if !wantBool then "a boolean expression is not a string operand" else shapeProblem n.operand true)
    else if n.kind == "eq" || n.kind == "ne" then
      (
        if !wantBool then
          "a comparison is not a string operand"
        else
          firstProblem (nonEmpty [
            (shapeProblem n.lhs false)
            (shapeProblem n.rhs false)
          ])
      )
    else if n.kind == "in" then
      (
        if !wantBool then
          "a comparison is not a string operand"
        else
          let
            l = shapeProblem n.lhs false;
          in
          if l != "" then
            l
          else if n.rhs.kind != "list" then
            "the right-hand side of `in` must be a list literal"
          else
            firstProblem (nonEmpty (map (item: shapeProblem item false) n.rhs.items))
      )
    else
      "unrecognised predicate node";

  # Validate `source` as a predicate of the built-in grammar. Returns
  # `{ ok = true; ast; }` or `{ ok = false; class; message; identifier?; }`,
  # `class` being "unknown-identifier" (`EUnknownPredicate`) or "invalid"
  # (`EUnstructured`) -- the two classes `cases.json` distinguishes.
  validate =
    source:
    let
      parsed = parse source;
      unknown = if parsed ? ast then unknownIdents parsed.ast else [ ];
      problem = if parsed ? ast then shapeProblem parsed.ast true else "";
    in
    if parsed ? error then
      {
        ok = false;
        class = "invalid";
        message = parsed.error;
      }
    else if unknown != [ ] then
      {
        ok = false;
        class = "unknown-identifier";
        identifier = head unknown;
        message = "unknown predicate identifier '${head unknown}'";
      }
    else if problem != "" then
      {
        ok = false;
        class = "invalid";
        message = "`${source}` (${problem}): expected a predicate of the built-in grammar";
      }
    else
      {
        ok = true;
        inherit (parsed) ast;
      };

  # ---------------------------------------------------------------------------
  # Evaluator (`evaluateBool` / `predicateHolds`) over facts
  # `{ platform; arch; host; wsl; }`. Only validated ASTs reach it.
  # ---------------------------------------------------------------------------
  resolveString =
    facts: n:
    if n.kind == "str" then
      n.value
    else if n.kind == "ident" && lower n.name == standardHostIdent then
      facts.host
    else
      throw "predicate comparison only supports `host` and string literals";

  evaluate =
    facts: n:
    if n.kind == "bool" then
      n.value
    else if n.kind == "ident" then
      let
        id = lower n.name;
      in
      if id == "wsl" then
        facts.wsl
      else if elem id standardPlatformIdents then
        facts.platform == id
      else if elem id standardArchIdents then
        facts.arch == id
      else
        throw "predicate identifier '${n.name}' is not a boolean built-in"
    else if n.kind == "and" then
      all (evaluate facts) n.operands
    else if n.kind == "or" then
      any (evaluate facts) n.operands
    else if n.kind == "not" then
      !(evaluate facts n.operand)
    else if n.kind == "eq" then
      resolveString facts n.lhs == resolveString facts n.rhs
    else if n.kind == "ne" then
      resolveString facts n.lhs != resolveString facts n.rhs
    else if n.kind == "in" then
      elem (resolveString facts n.lhs) (map (resolveString facts) n.rhs.items)
    else
      throw "a ${n.kind} cannot stand alone as a boolean predicate";

  # Whether `source` holds for `facts`; `null` (no guard) always holds.
  # Throws, naming the predicate, when it is not of the built-in grammar.
  holds =
    facts: source:
    if source == null then
      true
    else
      let
        v = validate source;
      in
      if v.ok then
        evaluate facts v.ast
      else
        throw "reprobuild: `${source}` is not a predicate of the built-in grammar: ${v.message}";
in
{
  inherit
    lex
    parse
    validate
    evaluate
    holds
    isStandardIdent
    ;
}
