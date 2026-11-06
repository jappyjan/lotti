cmake_minimum_required(VERSION 3.20)
project(wisp_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(WISP_CORE_SOURCES src/crc.c src/frame.c src/msg.c src/msgs.c src/codec.c src/session.c
    src/sha256.c src/pool.c src/display.c src/resource.c src/text.c src/anim.c src/input.c src/engine.c)
set(WISP_WARNINGS -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror)

option(WISP_TESTS "Build the tests" ${PROJECT_IS_TOP_LEVEL})
option(WISP_SANITIZE "Build with ASan and UBSan" ${PROJECT_IS_TOP_LEVEL})
if(WISP_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

add_library(wisp_core STATIC ${WISP_CORE_SOURCES})
target_include_directories(wisp_core PUBLIC include)
target_compile_options(wisp_core PRIVATE ${WISP_WARNINGS})

if(WISP_TESTS)
  enable_testing()
  set(VECTORS ${CMAKE_CURRENT_SOURCE_DIR}/../wisp-proto/vectors)

  add_executable(test_core tests/test_core.c)
  target_link_libraries(test_core wisp_core)
  add_test(NAME core COMMAND test_core)

  add_executable(test_engine tests/test_engine.c)
  target_link_libraries(test_engine wisp_core)
  add_test(NAME engine COMMAND test_engine)

  add_executable(test_vectors tests/test_vectors.c tests/json.c)
  target_link_libraries(test_vectors wisp_core)
  add_test(NAME vectors COMMAND test_vectors ${VECTORS})

  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    add_test(NAME generated_c_fresh COMMAND Python3::Interpreter tools/gen_c.py --check
             WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    add_test(NAME vectors_fresh COMMAND Python3::Interpreter tools/gen_vectors.py --check
             WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  endif()
endif()
