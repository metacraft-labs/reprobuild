extern int hcr_external_seed;

int hcr_data_bias = 29;
const char hcr_label[] = "new-object";

__attribute__((noinline))
int hcr_changed_function(int value) {
  return (value * 3) + hcr_data_bias + 5;
}

__attribute__((noinline))
int hcr_caller(int value) {
  return hcr_changed_function(value) + hcr_external_seed + hcr_data_bias;
}
