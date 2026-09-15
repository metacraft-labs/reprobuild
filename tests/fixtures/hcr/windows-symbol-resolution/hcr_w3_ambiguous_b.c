static __declspec(noinline) int hx_w3_ambiguous(int value) {
  return value + 202;
}

int hx_w3_keep_ambiguous_b(int value) {
  return hx_w3_ambiguous(value);
}
