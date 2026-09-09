# Consumer used by the CI integration test: links against the fmt and spdlog
# installed by the action and prints the versions it was compiled against.
cmake_minimum_required(VERSION 3.16)
project(consumer CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(fmt REQUIRED)
find_package(spdlog REQUIRED)
add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE spdlog::spdlog fmt::fmt)
