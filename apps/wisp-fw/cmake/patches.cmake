# SPDX-License-Identifier: MIT
#
# Configure-time check for Wisp's non-EM9305 patches to the fork (third_party/ambiq/patches/,
# applied by scripts/setup.sh). The EM9305 patches are rule 8's business (cmake/rule8.cmake);
# these are correctness fixes every build needs:
#
#   zephyr-0002-i2c-ambiq-offset-byte-order.patch   multi-byte I2C register headers (nPM1300)
#                                                     go out in buffer order, not reversed
#
# `git apply --reverse --check` succeeds only if the exact patch is in the tree.
option(WISP_PATCHES_TEST_UNPATCHED
  "TEST ONLY: skip the check so wisp-fw:drivers-test can show the driver test catches an unpatched tree"
  OFF)
file(GLOB _wisp_fix_patches ${CMAKE_CURRENT_LIST_DIR}/../third_party/ambiq/patches/*.patch)
list(FILTER _wisp_fix_patches EXCLUDE REGEX "em9305")
foreach(_p ${_wisp_fix_patches})
  get_filename_component(_name ${_p} NAME)
  if(_name MATCHES "^zephyr-")
    set(_dir ${ZEPHYR_BASE})
  elseif(_name MATCHES "^hal_ambiq-")
    set(_dir ${ZEPHYR_HAL_AMBIQ_MODULE_DIR})
  else()
    message(FATAL_ERROR "WISP: patch ${_name} names no known west project.")
  endif()
  execute_process(
    COMMAND git -C ${_dir} apply --reverse --check ${_p}
    RESULT_VARIABLE _rc OUTPUT_QUIET ERROR_QUIET)
  if(NOT _rc EQUAL 0)
    if(WISP_PATCHES_TEST_UNPATCHED)
      message(WARNING "WISP: TEST ONLY build without ${_name}.")
    else()
      message(FATAL_ERROR "WISP: patch missing: ${_name} is not applied to ${_dir}. "
        "Run `pnpm nx run wisp-fw:setup` (third_party/ambiq/README.md).")
    endif()
  endif()
endforeach()
