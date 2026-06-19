// M3 JavaScript fixture for trace-based incremental testing.
//
// Three functions live here. `main` calls `used_a` and `used_b`; `unused_c`
// is defined but never called. The hand-built trace (see ../trace) therefore
// has Call records only for main/used_a/used_b, so the executed-function set is
// exactly {main, used_a, used_b} and `unused_c` is absent.
//
// JavaScript is brace-delimited, so the `.js` extractor captures each body
// from the function's opening `{` to its matching `}`, ignoring braces inside
// strings and comments. `used_a` deliberately contains a NESTED object brace
// and a brace inside a string/comment to exercise the brace matcher.
//
// Line numbers matter: the trace's Function records carry the definition lines
// below, and the engine extracts the function body from this source by line.
// Keep the `function` lines stable:
//   used_a   -> line 21
//   used_b   -> line 26
//   unused_c -> line 30
//   main     -> line 34

function used_a() {
  const obj = { a: 1, b: { c: 2 } }; // a brace "}" in a string and comment }
  return obj.a + obj.b.c;
}

function used_b() {
  return 2 + 2;
}

function unused_c() {
  return 3 + 3;
}

function main() {
  used_a();
  used_b();
}

main();
