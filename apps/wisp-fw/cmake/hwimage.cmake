# SPDX-License-Identifier: MIT
# Hardware-image gate (docs/wisp/rung4.md G11, G12), at configure time. Only for builds that set
# CONFIG_WISP_HW_IMAGE (images/native-*/), i.e. images that may one day be pinned and written to a
# temple. Development and emulation builds are not affected.
#
#   - The panel stays off: the uled node and its bus (MSPI0) must be disabled. BUCK1's voltage on Jan's hardware 5
#     (JBD4010) is read from stock as npmx code 1, taken to be 1.1 V [I]; the board default used
#     to be the A6N-G's 1.8 V. Until W21's PMIC snapshot gives the real code, no hardware image
#     may power the panel at all.
#   - No PMIC configuration writes: the pmic node and its children must be disabled, so Zephyr's
#     MFD (SHIP/LPRESET, GPIO mode), regulator and charger drivers never run. power.c's observe
#     mode then writes only the watchdog (stock's sequence) and the ADC's VBAT task. Enabling them
#     needs each value checked against W21's snapshot (G12).
#   - No test-only switch, and an image kind other than 255 (development).
if(NOT CONFIG_WISP_HW_IMAGE)
  return()
endif()

set(_hw_errors "")
# Kconfig's DT_HAS_<compatible>_ENABLED: y when an enabled node has that compatible.
# The panel, its bus, and every nPM13xx node (whatever children a later DTS adds).
get_cmake_property(_vars VARIABLES)
foreach(_var ${_vars})
  if(_var MATCHES "^CONFIG_DT_HAS_(EVEN_G2_ULED|AMBIQ_MSPI_CONTROLLER|NORDIC_NPM13[0-9A-Z_]*)_ENABLED$"
     AND ${_var})
    list(APPEND _hw_errors "an enabled devicetree node is ${CMAKE_MATCH_1} (${_var})")
  endif()
endforeach()
foreach(_opt CONFIG_WISP_DRIVER_SELFTEST)
  if(${_opt})
    list(APPEND _hw_errors "${_opt} is set (test only)")
  endif()
endforeach()
foreach(_var WISP_RULE8_CANARY WISP_MRAM_CANARY WISP_RULE8_TEST_UNPATCHED WISP_PATCHES_TEST_UNPATCHED)
  if(${_var})
    list(APPEND _hw_errors "${_var} is set (test only)")
  endif()
endforeach()
if(CONFIG_WISP_IMAGE_KIND EQUAL 255)
  list(APPEND _hw_errors "CONFIG_WISP_IMAGE_KIND is 255 (development build)")
endif()
if(_hw_errors)
  list(JOIN _hw_errors "\n  " _msg)
  message(FATAL_ERROR "WISP HARDWARE IMAGE GATE (rung4.md G11/G12) failed:\n  ${_msg}\n"
          "The panel and the PMIC's rails and charger stay untouched until W21's PMIC snapshot "
          "confirms their values.")
endif()
message(STATUS "Wisp hardware image gate: panel off, PMIC observe-only, no test switches")
