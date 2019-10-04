# CMakeList.txt : CMake project for OGL_SDL, include source and define
# project specific logic here.
#

project(blimp)
add_library(blimpLib "")

find_package(OpenGL REQUIRED)
find_package(SDL2 CONFIG REQUIRED)
find_package(SDL2-Image CONFIG REQUIRED)
find_package(GLEW REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(glm CONFIG REQUIRED)

# Add source to this project's executable.
target_link_libraries(blimpLib PRIVATE ${OPENGL_LIBRARY})
target_link_libraries(blimpLib PRIVATE SDL2::SDL2 SDL2::SDL2main)
target_link_libraries(blimpLib PRIVATE SDL2::SDL2_image)
target_link_libraries(blimpLib PRIVATE GLEW::GLEW)
target_link_libraries(blimpLib PRIVATE spdlog::spdlog)
target_link_libraries(blimpLib PRIVATE glm)
# TODO: Add tests and install targets if needed.

add_subdirectory(src)