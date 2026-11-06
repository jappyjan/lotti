# SPDX-License-Identifier: MIT
#
# Wisp native firmware (Zephyr, AmbiqMicro/ambiqzephyr fork). Build with
# `pnpm nx run wisp-fw:build`; see README.md.

cmake_minimum_required(VERSION 3.20.0)

list(APPEND BOARD_ROOT ${CMAKE_CURRENT_LIST_DIR})
if(NOT DEFINED BOARD)
  set(BOARD wisp_g2)
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wisp_fw C)

# --- Safety rule 8, configure-time gate (docs/wisp/safety.md) ------------------------------
# The post-build gate (scripts/check_rule8.py) inspects what actually got linked; this one
# fails early on the Kconfig switches that pull the EM9305 driver in.
include(${CMAKE_CURRENT_LIST_DIR}/cmake/rule8.cmake)

# --- App ----------------------------------------------------------------------------------
execute_process(
  COMMAND git -C ${CMAKE_CURRENT_LIST_DIR} describe --always --dirty --abbrev=10
  OUTPUT_VARIABLE WISP_FW_GIT_REV
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(WISP_FW_GIT_REV)
  target_compile_definitions(app PRIVATE WISP_FW_GIT_REV="${WISP_FW_GIT_REV}")
endif()

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE src src/hal src/link)
if(CONFIG_WISP_BLE)
  # The Wisp GATT service (Zephyr, transport only) and the transport adapter (portable C,
  # host-tested in tests/link/). Both need wisp-core.
  set(WISP_WITH_CORE ON)
  target_sources(app PRIVATE src/ble/wisp_ble.c src/link/wisp_link.c)
  target_include_directories(app PRIVATE src/ble)
endif()
if(CONFIG_NEWLIB_LIBC AND CONFIG_MBEDTLS)
  target_sources(app PRIVATE src/compat/newlib_fini.c)
endif()

# Wisp Boot (src/boot/) is a design stub in M0: host-tested by tests/boot, not linked into
# the image entry. Rung 3 wires it in as the first stage at 0x438000.

# --- Wisp core hook -----------------------------------------------------------------------
# packages/wisp-core (portable C, owned by its own thread) links in here once it exposes a
# CMake library target. Point WISP_CORE_DIR at it (default: the monorepo path, if present)
# and set WISP_WITH_CORE=ON. The core must not depend on Zephyr; it talks to src/hal/.
option(WISP_WITH_CORE "Link packages/wisp-core into the image (forced on with CONFIG_WISP_BLE)" OFF)
set(WISP_CORE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../packages/wisp-core" CACHE PATH
    "Path to the wisp-core source tree (must contain a CMakeLists.txt defining wisp_core)")
if(WISP_WITH_CORE)
  if(NOT EXISTS "${WISP_CORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "WISP_WITH_CORE=ON but ${WISP_CORE_DIR}/CMakeLists.txt does not exist")
  endif()
  add_subdirectory(${WISP_CORE_DIR} ${CMAKE_BINARY_DIR}/wisp_core)
  # Zephyr's flags (-mcpu, defines), with its headers as system headers: the core builds with
  # -Wpedantic -Werror and Zephyr's libc wrappers use #include_next.
  target_include_directories(wisp_core SYSTEM PRIVATE
    $<TARGET_PROPERTY:zephyr_interface,INTERFACE_INCLUDE_DIRECTORIES>)
  target_link_libraries(wisp_core PRIVATE zephyr_interface)
  target_link_libraries(app PRIVATE wisp_core)
  target_compile_definitions(app PRIVATE WISP_WITH_CORE=1)
endif()

# --- Test-only: rule 8 canary -------------------------------------------------------------
# Links the EM9305 firmware image from the HAL on purpose so wisp-fw:test can prove the
# post-build gate catches it. Never set outside scripts/test.sh.
option(WISP_RULE8_CANARY "TEST ONLY: link the EM9305 image to exercise check_rule8.py" OFF)
if(WISP_RULE8_CANARY)
  target_sources(app PRIVATE tests/rule8/canary.c)
  target_include_directories(app PRIVATE
    ${ZEPHYR_HAL_AMBIQ_MODULE_DIR}/components/bluetooth)
endif()

# --- Post-build gates ---------------------------------------------------------------------
# Rule 1+3 (image shape) and rule 8 (no EM9305 image / update path), run after every link as
# part of the default target. Either failing fails the build, and the stamp is not written, so
# they rerun on the next build (zephyr.elf itself stays in the build dir for inspection; the
# nx build target only reports success when both pass).
if(NOT CONFIG_BOARD_WISP_G2)
  # native_sim (tests/ble/) is a Linux process: no MRAM image, no EM9305 driver.
  return()
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(_wisp_zdir ${CMAKE_BINARY_DIR}/zephyr)
set(_wisp_stamp ${CMAKE_BINARY_DIR}/wisp_checks.stamp)
add_custom_command(
  OUTPUT ${_wisp_stamp}
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_LIST_DIR}/scripts/check_image.py
          --elf ${_wisp_zdir}/${KERNEL_ELF_NAME}
          --bin ${_wisp_zdir}/${KERNEL_BIN_NAME}
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_LIST_DIR}/scripts/check_rule8.py
          --elf ${_wisp_zdir}/${KERNEL_ELF_NAME}
          --bin ${_wisp_zdir}/${KERNEL_BIN_NAME}
          --map ${_wisp_zdir}/${KERNEL_MAP_NAME}
          --config ${_wisp_zdir}/.config
          --compile-commands ${CMAKE_BINARY_DIR}/compile_commands.json
          --hal ${ZEPHYR_HAL_AMBIQ_MODULE_DIR}
          --zephyr ${ZEPHYR_BASE}
          --nm ${CMAKE_NM}
          --objdump ${CMAKE_OBJDUMP}
  COMMAND ${CMAKE_COMMAND} -E touch ${_wisp_stamp}
  DEPENDS ${logical_target_for_zephyr_elf}
          ${_wisp_zdir}/${KERNEL_ELF_NAME}
          ${_wisp_zdir}/${KERNEL_BIN_NAME}
          ${CMAKE_CURRENT_LIST_DIR}/scripts/check_image.py
          ${CMAKE_CURRENT_LIST_DIR}/scripts/check_rule8.py
          ${CMAKE_CURRENT_LIST_DIR}/scripts/wisp_layout.py
  COMMENT "Wisp post-build gates: image layout (rules 1, 3) and EM9305 (rule 8)"
  VERBATIM)
add_custom_target(wisp_checks ALL DEPENDS ${_wisp_stamp})
