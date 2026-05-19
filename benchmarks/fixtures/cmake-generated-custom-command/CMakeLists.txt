cmake_minimum_required(VERSION 3.20)

project(ReprobuildCMakeGeneratedBench C)

set(generated_c "${CMAKE_CURRENT_BINARY_DIR}/generated.c")
set(generated_h "${CMAKE_CURRENT_BINARY_DIR}/generated.h")

add_custom_command(
  OUTPUT "${generated_c}" "${generated_h}"
  COMMAND "${CMAKE_COMMAND}"
    "-DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/seed.txt"
    "-DOUTPUT_C=${generated_c}"
    "-DOUTPUT_H=${generated_h}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/generate.cmake"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/seed.txt" "${CMAKE_CURRENT_SOURCE_DIR}/generate.cmake"
  VERBATIM)

add_executable(genbench main.c "${generated_c}")
target_include_directories(genbench PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
