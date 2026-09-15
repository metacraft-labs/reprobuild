static __declspec(noinline) int hx_w3_ambiguous(int value) {
  return value + 101;
}

int hx_w3_keep_ambiguous_a(int value) {
  return hx_w3_ambiguous(value);
}
