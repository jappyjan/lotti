# SPDX-License-Identifier: MIT
# Hardware-image gate (docs/wisp/rung4.md G11, G12, W25), at configure time. Only for builds that set
# CONFIG_WISP_HW_IMAGE (images/native-*/), i.e. images that may one day be pinned and written to a
# temple. Development and emulation builds are not affected.
#
#   - No PMIC configuration writes: every nPM13xx node stays disabled, so Zephyr's MFD
#     (SHIP/LPRESET, GPIO mode), regulator and charger drivers never run. power.c writes only the
#     watchdog (stock's sequence) and the ADC's VBAT task.
#   - The panel only through the gated rail switches (W25): if the panel or its bus (MSPI0) is
#     enabled, it must be the JBD4010 (Jan's temples, hardware 5), its rails must be
#     wisp,npm1300-switch nodes (task writes only, after reading back stock's configuration), and
#     BUCK1's expected code must be W21's 0x01. native-0 kept the panel off altogether.
#   - No console, no log, no printk (W24 fix plan 3): UART1 disabled; the case UART, the boot report
#     and the record carry the diagnostics.
#   - No test-only switch, and an image kind other than 255 (development).
#
# native-0 (pinned at 8374f9a) predates the last two rules and is built from its own commit.
if(NOT CONFIG_WISP_HW_IMAGE)
  return()
endif()

set(_hw_errors "")
# Kconfig's DT_HAS_<compatible>_ENABLED: y when an enabled node has that compatible.
get_cmake_property(_vars VARIABLES)
foreach(_var ${_vars})
  if(_var MATCHES "^CONFIG_DT_HAS_(NORDIC_NPM13[0-9A-Z_]*)_ENABLED$" AND ${_var})
    list(APPEND _hw_errors "an enabled devicetree node is ${CMAKE_MATCH_1} (${_var})")
  endif()
endforeach()

set(_panel "off")
if(CONFIG_DT_HAS_EVEN_G2_ULED_ENABLED OR CONFIG_DT_HAS_AMBIQ_MSPI_CONTROLLER_ENABLED)
  set(_panel "on")
  dt_nodelabel(_uled NODELABEL uled)
  dt_prop(_name PATH ${_uled} PROPERTY panel)
  if(NOT _name STREQUAL "jbd4010")
    list(APPEND _hw_errors "the panel is '${_name}', not jbd4010 (Jan's temples report hardware 5)")
  endif()
  if(NOT CONFIG_WISP_NPM1300_SWITCH)
    list(APPEND _hw_errors "the panel is enabled without the gated rail switches (wisp,npm1300-switch)")
  endif()
  # That the panel's vdd/vio supplies are these switches is a BUILD_ASSERT in src/drivers/uled.c
  # (CMake's devicetree access does not follow phandles). Here: BUCK1's expected code.
  dt_comp_path(_switches COMPATIBLE "wisp,npm1300-switch")
  set(_buck1 "")
  foreach(_sw ${_switches})
    dt_prop(_rail_name PATH ${_sw} PROPERTY rail)
    if(_rail_name STREQUAL "buck1")
      dt_prop(_vout PATH ${_sw} PROPERTY expect-vout)
      set(_buck1 "${_vout}")
    endif()
  endforeach()
  if(NOT "${_buck1}" STREQUAL "1")
    list(APPEND _hw_errors "no BUCK1 switch expecting W21's code 0x01 (expect-vout '${_buck1}', "
         "images/pmic-baseline-w21.json)")
  endif()
endif()

foreach(_opt CONFIG_UART_CONSOLE CONFIG_CONSOLE CONFIG_LOG CONFIG_PRINTK)
  if(${_opt})
    list(APPEND _hw_errors "${_opt} is set (no console, log or printk on hardware images)")
  endif()
endforeach()
dt_nodelabel(_uart1 NODELABEL uart1)
dt_prop(_uart1_status PATH ${_uart1} PROPERTY status)
if(NOT _uart1_status STREQUAL "disabled")
  list(APPEND _hw_errors "UART1 is enabled (status '${_uart1_status}')")
endif()

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
  message(FATAL_ERROR "WISP HARDWARE IMAGE GATE (rung4.md G11/G12/W25) failed:\n  ${_msg}\n"
          "The PMIC's rails and charger stay untouched but for the gated panel switches, and "
          "hardware images carry no console.")
endif()
message(STATUS "Wisp hardware image gate: panel ${_panel} (gated rails), PMIC observe-only, "
        "no console, no test switches")
