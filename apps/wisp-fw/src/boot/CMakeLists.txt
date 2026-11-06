# SPDX-License-Identifier: MIT
# Wisp Boot: bare metal (no Zephyr), arm-none-eabi-gcc, linked at 0x438000 (stage/boot.ld).
# Built by scripts/build_boot.sh; outputs wisp_boot.{elf,bin,map} and compile_commands.json,
# which feed the same image + rule 8 gates as the Zephyr app. With -DWISP_BOOT_TEST_APPS=ON it
# also builds the rung-3 fault-injection apps (tests/boot/app/) and the combined native images.
cmake_minimum_required(VERSION 3.20)
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
project(wisp_boot C)

set(LITTLEFS_DIR "" CACHE PATH "littlefs source (west module modules/fs/littlefs)")
option(WISP_BOOT_TEST_APPS "build the rung-3 fault-injection apps" OFF)
if(NOT EXISTS ${LITTLEFS_DIR}/lfs.c)
  message(FATAL_ERROR "LITTLEFS_DIR must point at littlefs (got '${LITTLEFS_DIR}')")
endif()

set(CPU_FLAGS -mcpu=cortex-m55 -mthumb -mfloat-abi=soft)
set(COMMON_FLAGS ${CPU_FLAGS} -Os -g -ffreestanding -ffunction-sections -fdata-sections
    -Wall -Wextra -Werror)

add_executable(wisp_boot.elf
  wisp_boot.c
  stage/boot_start.c stage/boot_main.c stage/boot_hw.c stage/boot_nor.c
  ${LITTLEFS_DIR}/lfs.c ${LITTLEFS_DIR}/lfs_util.c)
target_include_directories(wisp_boot.elf PRIVATE . stage ${LITTLEFS_DIR})
# littlefs: static buffers only, no logging/asserts (no printf in Wisp Boot).
target_compile_definitions(wisp_boot.elf PRIVATE LFS_NO_MALLOC LFS_NO_DEBUG LFS_NO_WARN
  LFS_NO_ERROR LFS_NO_ASSERT)
target_compile_options(wisp_boot.elf PRIVATE ${COMMON_FLAGS})
set_source_files_properties(${LITTLEFS_DIR}/lfs.c ${LITTLEFS_DIR}/lfs_util.c PROPERTIES
  COMPILE_OPTIONS "-Wno-unused-parameter;-Wno-unused-function;-Wno-unused-variable")
target_link_options(wisp_boot.elf PRIVATE ${CPU_FLAGS} -nostartfiles --specs=nano.specs
  --specs=nosys.specs -Wl,--gc-sections -Wl,-T${CMAKE_CURRENT_SOURCE_DIR}/stage/boot.ld
  -Wl,-Map=${CMAKE_BINARY_DIR}/wisp_boot.map)
add_custom_command(TARGET wisp_boot.elf POST_BUILD
  COMMAND arm-none-eabi-objcopy -O binary wisp_boot.elf wisp_boot.bin
  COMMAND arm-none-eabi-size wisp_boot.elf)

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
  add_custom_target(native_images ALL DEPENDS ${NATIVE_IMAGES})
endif()
