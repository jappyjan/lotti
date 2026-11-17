# SPDX-License-Identifier: MIT
#
# Wisp native firmware (Zephyr, AmbiqMicro/ambiqzephyr fork). Build with
# `pnpm nx run wisp-fw:build`; see README.md.

cmake_minimum_required(VERSION 3.20.0)

list(APPEND BOARD_ROOT ${CMAKE_CURRENT_LIST_DIR})
if(NOT DEFINED BOARD)
  set(BOARD wisp_g2)
endif()

# --- Panel: no default (docs/wisp/rung4.md G11) ---------------------------------------------
# Which panel is fitted follows the temple's hw_version strap (5 = JBD4010, 6 = A6N-G), and the
# two need different rails. Every wisp_g2 build names it: WISP_PANEL=jbd4010 or a6n-g adds
# boards/panels/<panel>.overlay (which also sets BUCK1's voltage); WISP_PANEL=none is for image
# overlays that describe the panel themselves (images/native-*/).
if(NOT DEFINED WISP_PANEL AND DEFINED ENV{WISP_PANEL})
  set(WISP_PANEL $ENV{WISP_PANEL})
endif()
if(BOARD MATCHES "^wisp_g2")
  if(NOT "${WISP_PANEL}" MATCHES "^(jbd4010|a6n-g|none)$")
    message(FATAL_ERROR "wisp_g2 has no default panel (rung4.md G11): set WISP_PANEL=jbd4010 or "
            "a6n-g (boards/panels/), or none when an image overlay names it (got '${WISP_PANEL}')")
  endif()
  if(NOT WISP_PANEL STREQUAL "none")
    set(EXTRA_DTC_OVERLAY_FILE
        "${CMAKE_CURRENT_LIST_DIR}/boards/panels/${WISP_PANEL}.overlay;${EXTRA_DTC_OVERLAY_FILE}")
  endif()
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(wisp_fw C)

# --- Safety rule 8, configure-time gate (docs/wisp/safety.md) ------------------------------
# The post-build gate (scripts/check_rule8.py) inspects what actually got linked; this one
# fails early on the Kconfig switches that pull the EM9305 driver in.
include(${CMAKE_CURRENT_LIST_DIR}/cmake/rule8.cmake)
# Wisp's other patches to the fork (I2C header byte order), checked after rule 8 so a rule 8
# failure is reported first.
include(${CMAKE_CURRENT_LIST_DIR}/cmake/patches.cmake)
# Hardware images (images/native-*/): no panel power and no PMIC configuration writes until
# W21's snapshot, no test-only switches (rung4.md G11, G12).
include(${CMAKE_CURRENT_LIST_DIR}/cmake/hwimage.cmake)

# --- App ----------------------------------------------------------------------------------
execute_process(
  COMMAND git -C ${CMAKE_CURRENT_LIST_DIR} describe --always --dirty --abbrev=10
  OUTPUT_VARIABLE WISP_FW_GIT_REV
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET)
if(WISP_FW_GIT_REV)
  target_compile_definitions(app PRIVATE WISP_FW_GIT_REV="${WISP_FW_GIT_REV}")
endif()

target_sources(app PRIVATE src/main.c src/display/wisp_flush.c)
target_sources_ifdef(CONFIG_WISP_NATIVE_HAL app PRIVATE src/hal/native/power.c
  src/hal/native/display.c src/hal/native/input.c src/hal/native/sensors.c)
target_include_directories(app PRIVATE src src/hal src/hal/native src/display src/drivers src/link
  src/case src/diag)
if(CONFIG_BOARD_WISP_G2)
  # Wisp Boot's services table and status block (src/boot/), and the app's diagnostics in its
  # record (src/diag/). Of Wisp Boot's code the app links only its polled UART2 driver and its
  # polled PMIC kick, for the diagnostics' fallback loop when the STIMER is dead.
  target_sources(app PRIVATE src/boot_link.c src/diag/wisp_app_diag.c src/boot/stage/boot_uart.c
    src/boot/stage/boot_pmic.c
    src/case/wisp_case_proto.c)
  target_include_directories(app PRIVATE src/boot src/boot/stage)
endif()
target_sources_ifdef(CONFIG_WISP_CASE_UART app PRIVATE src/case/wisp_case.c)
if(CONFIG_WISP_BLE)
  # The Wisp GATT service (Zephyr, transport only) and the transport adapter (portable C,
  # host-tested in tests/link/). Both need wisp-core.
  set(WISP_WITH_CORE ON)
  target_sources(app PRIVATE src/ble/wisp_ble.c src/link/wisp_link.c)
  target_include_directories(app PRIVATE src/ble)
endif()

# --- Drivers (docs/wisp/hardware.md "Native drivers") -------------------------------------
target_sources_ifdef(CONFIG_WISP_G2_TOUCH app PRIVATE src/drivers/g2_touch.c)
target_sources_ifdef(CONFIG_WISP_ICM45608 app PRIVATE src/drivers/icm45608.c)
target_sources_ifdef(CONFIG_WISP_OPT3007 app PRIVATE src/drivers/opt3007.c)
target_sources_ifdef(CONFIG_WISP_ULED app PRIVATE src/drivers/uled.c)
target_sources_ifdef(CONFIG_WISP_NPM1300_SWITCH app PRIVATE src/drivers/npm1300_switch.c)
target_sources_ifdef(CONFIG_WISP_BOOT_SCREEN app PRIVATE src/display/boot_screen.c)
target_sources_ifdef(CONFIG_WISP_SOC_INIT app PRIVATE src/soc/wisp_soc_init.c)
if(CONFIG_NEWLIB_LIBC AND CONFIG_MBEDTLS)
  target_sources(app PRIVATE src/compat/newlib_fini.c)
endif()

# Wisp Boot (src/boot/) is built on its own (scripts/build_boot.sh) and put in front of this app
# by scripts/build_native.sh: the app is linked at 0x448000, Wisp Boot owns [0x438000, 0x448000).

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

# --- Test-only: MRAM write canary --------------------------------------------------------
# Links hal_ambiq's MRAM program path so wisp-fw:test can prove check_no_mram_write.py (rung4.md
# G13) catches it. Never set outside scripts/test.sh.
option(WISP_MRAM_CANARY "TEST ONLY: link am_hal_mram_main_program to exercise check_no_mram_write.py" OFF)
if(WISP_MRAM_CANARY)
  target_sources(app PRIVATE tests/mram/canary.c)
endif()

# --- Post-build gates ---------------------------------------------------------------------
# Rule 1+3 (image shape: the app at 0x448000, its RAM below Wisp Boot's), rule 8 (no EM9305
# image / update path) and G13 (no MRAM write path), run after every link as part of the
# default target. Any one failing fails the build, and the stamp is not written, so
# they rerun on the next build (zephyr.elf itself stays in the build dir for inspection; the
# nx build target only reports success when all pass).
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
          --part app
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
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_LIST_DIR}/scripts/check_no_mram_write.py
          --elf ${_wisp_zdir}/${KERNEL_ELF_NAME}
          --bin ${_wisp_zdir}/${KERNEL_BIN_NAME}
          --map ${_wisp_zdir}/${KERNEL_MAP_NAME}
          --config ${_wisp_zdir}/.config
          --nm ${CMAKE_NM}
          --objdump ${CMAKE_OBJDUMP}
  COMMAND ${CMAKE_COMMAND} -E touch ${_wisp_stamp}
  DEPENDS ${logical_target_for_zephyr_elf}
          ${_wisp_zdir}/${KERNEL_ELF_NAME}
          ${_wisp_zdir}/${KERNEL_BIN_NAME}
          ${CMAKE_CURRENT_LIST_DIR}/scripts/check_image.py
          ${CMAKE_CURRENT_LIST_DIR}/scripts/check_rule8.py
          ${CMAKE_CURRENT_LIST_DIR}/scripts/check_no_mram_write.py
          ${CMAKE_CURRENT_LIST_DIR}/scripts/wisp_layout.py
  COMMENT "Wisp post-build gates: image layout (rules 1, 3), EM9305 (rule 8), no MRAM write (G13)"
  VERBATIM)
add_custom_target(wisp_checks ALL DEPENDS ${_wisp_stamp})
