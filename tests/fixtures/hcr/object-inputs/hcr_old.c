extern int hcr_external_seed;

int hcr_data_bias = 17;
const char hcr_label[] = "old-object";

__attribute__((noinline))
int hcr_changed_function(int value) {
  return value + hcr_data_bias + 1;
}

__attribute__((noinline))
int hcr_caller(int value) {
  return hcr_changed_function(value) + hcr_external_seed;
}
