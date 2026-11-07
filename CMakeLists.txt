cmake_minimum_required(VERSION 3.20)
project(flint LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(flint src/main.cpp)
target_compile_options(flint PRIVATE -Wall -Wextra -Wpedantic)
