cmake_minimum_required(VERSION 3.20)
project(feature_libraries C)

# One library source compiled twice, once per feature, and two top-level
# executables that each link the copy with their feature.
add_library(featlib_alpha STATIC featlib/featlib.c)
target_compile_definitions(featlib_alpha PRIVATE FEATLIB_ALPHA)
add_library(featlib_beta STATIC featlib/featlib.c)
target_compile_definitions(featlib_beta PRIVATE FEATLIB_BETA)

add_executable(app_alpha app/main.c)
target_link_libraries(app_alpha PRIVATE featlib_alpha)
add_executable(app_beta app/main.c)
target_link_libraries(app_beta PRIVATE featlib_beta)
