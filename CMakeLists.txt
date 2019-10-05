# CMakeList.txt : CMake project for OGL_SDL, include source and define
# project specific logic here.
#
cmake_minimum_required (VERSION 3.13)

project(blimp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

add_subdirectory(blimp)
add_subdirectory(sandbox)