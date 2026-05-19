if(NOT DEFINED INPUT OR NOT DEFINED OUTPUT_C OR NOT DEFINED OUTPUT_H)
  message(FATAL_ERROR "INPUT, OUTPUT_C, and OUTPUT_H are required")
endif()

file(READ "${INPUT}" seed)
string(STRIP "${seed}" seed)
string(LENGTH "${seed}" seed_len)

file(WRITE "${OUTPUT_H}"
  "#pragma once\n"
  "int generated_value(void);\n")

file(WRITE "${OUTPUT_C}"
  "#include \"generated.h\"\n"
  "int generated_value(void) { return ${seed_len}; }\n")
