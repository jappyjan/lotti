# SPDX-License-Identifier: MIT
# Wisp Boot: bare metal (no Zephyr), arm-none-eabi-gcc, linked at 0x438000 (stage/boot.ld).
# Built by scripts/build_boot.sh; outputs wisp_boot.{elf,bin,map} and compile_commands.json,
# which feed the same image + rule 8 gates as the Zephyr app. With -DWISP_BOOT_TEST_APPS=ON it
# also builds the rung-3 fault-injection apps (tests/boot/app/) and the combined native images;
# -DWISP_REAL_APP=<zephyr.bin linked at 0x448000> adds native_real.bin (the real Wisp app behind
# this Wisp Boot). -DWISP_BOOT_OBSERVE=ON builds the observe-only Wisp Boot (rung4.md native-0:
# no NOR or MRAM write code, always run-app); -DWISP_BOOT_LOG=OFF drops the UART1 debug log
# (hardware images); -DWISP_BOOT_NOR=OFF (observe builds only) skips the NOR phase entirely
# (rung4.md W24e: run-app with the breadcrumb boot-nor-skipped, MSPI1 never touched).
cmake_minimum_required(VERSION 3.20)
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
project(wisp_boot C)

set(LITTLEFS_DIR "" CACHE PATH "littlefs source (west module modules/fs/littlefs)")
option(WISP_BOOT_TEST_APPS "build the rung-3 fault-injection apps" OFF)
option(WISP_BOOT_OBSERVE "observe-only build: every write compiled out, always run-app" OFF)
option(WISP_BOOT_LOG "UART1 debug log" ON)
option(WISP_BOOT_NOR "the NOR phase (OFF: observe builds only; run-app without touching MSPI1)" ON)
option(WISP_STAGE0 "also build stage-0, the bare-metal app (src/stage0/)" OFF)
set(WISP_REAL_APP "" CACHE FILEPATH "the real Wisp app (zephyr.bin at 0x448000) for native_real.bin")
if(NOT EXISTS ${LITTLEFS_DIR}/lfs.c)
  message(FATAL_ERROR "LITTLEFS_DIR must point at littlefs (got '${LITTLEFS_DIR}')")
endif()

set(CPU_FLAGS -mcpu=cortex-m55 -mthumb -mfloat-abi=soft)
set(COMMON_FLAGS ${CPU_FLAGS} -Os -g -ffreestanding -ffunction-sections -fdata-sections
    -Wall -Wextra -Werror)

add_executable(wisp_boot.elf
  wisp_boot.c
  stage/boot_start.c stage/boot_main.c stage/boot_hw.c stage/boot_nor.c
  stage/boot_pmic.c stage/boot_uart.c ../case/wisp_case_proto.c
  ${LITTLEFS_DIR}/lfs.c ${LITTLEFS_DIR}/lfs_util.c)
target_include_directories(wisp_boot.elf PRIVATE . stage ../case ${LITTLEFS_DIR})
# littlefs: static buffers only, no logging/asserts (no printf in Wisp Boot).
target_compile_definitions(wisp_boot.elf PRIVATE LFS_NO_MALLOC LFS_NO_DEBUG LFS_NO_WARN
  LFS_NO_ERROR LFS_NO_ASSERT)
target_compile_options(wisp_boot.elf PRIVATE ${COMMON_FLAGS})
if(WISP_BOOT_OBSERVE)
  # LFS_READONLY: littlefs without any write path (no prog/erase callbacks are set either).
  target_compile_definitions(wisp_boot.elf PRIVATE WISP_BOOT_OBSERVE=1 LFS_READONLY)
endif()
if(NOT WISP_BOOT_NOR)
  if(NOT WISP_BOOT_OBSERVE)
    message(FATAL_ERROR "WISP_BOOT_NOR=OFF needs WISP_BOOT_OBSERVE=ON (the fallback build rescues from the NOR)")
  endif()
  target_compile_definitions(wisp_boot.elf PRIVATE WISP_BOOT_NOR=0)
endif()
if(NOT WISP_BOOT_LOG)
  target_compile_definitions(wisp_boot.elf PRIVATE WISP_BOOT_LOG=0)
endif()
set_source_files_properties(${LITTLEFS_DIR}/lfs.c ${LITTLEFS_DIR}/lfs_util.c PROPERTIES
  COMPILE_OPTIONS "-Wno-unused-parameter;-Wno-unused-function;-Wno-unused-variable")
target_link_options(wisp_boot.elf PRIVATE ${CPU_FLAGS} -nostartfiles --specs=nano.specs
  --specs=nosys.specs -Wl,--gc-sections -Wl,-T${CMAKE_CURRENT_SOURCE_DIR}/stage/boot.ld
  -Wl,-Map=${CMAKE_BINARY_DIR}/wisp_boot.map)
add_custom_command(TARGET wisp_boot.elf POST_BUILD
  COMMAND arm-none-eabi-objcopy -O binary wisp_boot.elf wisp_boot.bin
  COMMAND arm-none-eabi-size wisp_boot.elf)

if(WISP_STAGE0)
  # stage-0 (rung4.md W24b): linked at 0x448000, shares Wisp Boot's UART2 and PMIC-kick code and
  # the case-UART codec. scripts/build_native.sh stage-0 combines it with the observe-only Wisp Boot.
  set(S0_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../stage0)
  add_executable(stage0.elf ${S0_DIR}/stage0.c stage/boot_pmic.c stage/boot_uart.c
    ../case/wisp_case_proto.c)
  target_include_directories(stage0.elf PRIVATE . stage ../case)
  execute_process(COMMAND git -C ${CMAKE_CURRENT_SOURCE_DIR} describe --always --dirty --abbrev=10
    OUTPUT_VARIABLE WISP_STAGE0_REV OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(WISP_STAGE0_REV)
    target_compile_definitions(stage0.elf PRIVATE STAGE0_REV="${WISP_STAGE0_REV}")
  endif()
  target_compile_options(stage0.elf PRIVATE ${COMMON_FLAGS})
  target_link_options(stage0.elf PRIVATE ${CPU_FLAGS} -nostartfiles --specs=nano.specs
    --specs=nosys.specs -Wl,--gc-sections -Wl,-T${S0_DIR}/stage0.ld
    -Wl,-Map=${CMAKE_BINARY_DIR}/stage0.map)
  add_custom_command(TARGET stage0.elf POST_BUILD
    COMMAND arm-none-eabi-objcopy -O binary stage0.elf stage0.bin
    COMMAND arm-none-eabi-size stage0.elf)
endif()

if(WISP_BOOT_TEST_APPS)
  set(APP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../tests/boot/app)
  foreach(mode good hang crash_reset crash_after no_feed)
    add_executable(app_${mode}.elf ${APP_DIR}/fault_app.c)
    string(TOUPPER ${mode} MODE)
    target_compile_definitions(app_${mode}.elf PRIVATE FAULT_${MODE}=1)
    target_include_directories(app_${mode}.elf PRIVATE . stage)
    target_compile_options(app_${mode}.elf PRIVATE ${COMMON_FLAGS})
    target_link_options(app_${mode}.elf PRIVATE ${CPU_FLAGS} -nostartfiles -nostdlib
      -Wl,--gc-sections -Wl,-T${APP_DIR}/app.ld -Wl,-Map=${CMAKE_BINARY_DIR}/app_${mode}.map)
    add_custom_command(TARGET app_${mode}.elf POST_BUILD
      COMMAND arm-none-eabi-objcopy -O binary app_${mode}.elf app_${mode}.bin)
    # The native image as wisp-ota would pack it: Wisp Boot padded to 64 KiB, then the app.
    # Rebuilt whenever either part changes.
    add_custom_command(OUTPUT native_${mode}.bin
      COMMAND ${CMAKE_COMMAND} -DBOOT=wisp_boot.bin -DAPP=app_${mode}.bin
              -DOUT=native_${mode}.bin -P ${APP_DIR}/combine.cmake
      DEPENDS wisp_boot.elf app_${mode}.elf ${APP_DIR}/combine.cmake)
    list(APPEND NATIVE_IMAGES native_${mode}.bin)
  endforeach()
  # No app at all: Wisp Boot followed by an erased (0xFF) app slot of 4 KiB.
  add_custom_command(OUTPUT native_erased.bin
    COMMAND ${CMAKE_COMMAND} -DBOOT=wisp_boot.bin -DAPP=ERASED
            -DOUT=native_erased.bin -P ${APP_DIR}/combine.cmake
    DEPENDS wisp_boot.elf ${APP_DIR}/combine.cmake)
  list(APPEND NATIVE_IMAGES native_erased.bin)
  if(WISP_STAGE0)
    add_custom_command(OUTPUT native_stage0.bin
      COMMAND ${CMAKE_COMMAND} -DBOOT=wisp_boot.bin -DAPP=stage0.bin
              -DOUT=native_stage0.bin -P ${APP_DIR}/combine.cmake
      DEPENDS wisp_boot.elf stage0.elf ${APP_DIR}/combine.cmake)
    list(APPEND NATIVE_IMAGES native_stage0.bin)
  endif()
  if(WISP_REAL_APP)
    add_custom_command(OUTPUT native_real.bin
      COMMAND ${CMAKE_COMMAND} -DBOOT=wisp_boot.bin -DAPP=${WISP_REAL_APP}
              -DOUT=native_real.bin -P ${APP_DIR}/combine.cmake
      DEPENDS wisp_boot.elf ${WISP_REAL_APP} ${APP_DIR}/combine.cmake)
    list(APPEND NATIVE_IMAGES native_real.bin)
  endif()
  add_custom_target(native_images ALL DEPENDS ${NATIVE_IMAGES})
endif()
