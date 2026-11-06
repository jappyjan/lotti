# SPDX-License-Identifier: MIT
#
# Safety rule 8 (docs/wisp/safety.md): never let firmware reflash a co-processor.
#
# Ambiq's am_devices_em9305_init() erases and reflashes the EM9305's NVM when the device
# firmware looks older than (or equal to) the bundled ble_fw_image_em9305.h, and when the
# controller fails to boot — unless the caller sets skip_fw_update. Even ships its own
# EM9305 build, so that path would wipe the radio. Kconfig switches that compile the driver:
#
#   CONFIG_BT                               -> drivers/bluetooth/hci/apollox_blue.c, which
#                                              calls am_devices_em9305_init() with
#                                              skip_fw_update left false (unpatched fork
#                                              89c8a36; Wisp's patch forces it true)
#   CONFIG_AMBIQ_COMPONENT_USE_BT           -> compiles am_devices_em9305.c (+ the image)
#   CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT-> evb board.c path: skip_fw_update = CONFIG_BT,
#                                              i.e. false when BT is off
#   CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM -> writes EM9305 NVM info page 2
#   CONFIG_BT_HCI_SET_PUBLIC_ADDR           -> vendor command 0xFC43 (persistence unknown)

set(_wisp_rule8 "WISP SAFETY RULE 8 (docs/wisp/safety.md)")

if(CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT)
  message(FATAL_ERROR "${_wisp_rule8}: CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT=y runs "
    "am_devices_em9305_init() with skip_fw_update=false when BT is off (EM9305 reflash).")
endif()

if(CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM)
  message(FATAL_ERROR "${_wisp_rule8}: CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM=y writes "
    "the EM9305 NVM info page.")
endif()

if(CONFIG_BT_HCI_SET_PUBLIC_ADDR)
  message(FATAL_ERROR "${_wisp_rule8}: CONFIG_BT_HCI_SET_PUBLIC_ADDR=y sends the EM9305 a "
    "vendor command whose persistence is undocumented; the controller keeps its own address.")
endif()

if(CONFIG_BT OR CONFIG_AMBIQ_COMPONENT_USE_BT)
  if(NOT CONFIG_WISP_BT_ALLOWED)
    message(FATAL_ERROR "${_wisp_rule8}: Bluetooth / the EM9305 driver is enabled without "
      "CONFIG_WISP_BT_ALLOWED=y.")
  endif()
  if(NOT CONFIG_WISP_EM9305_SKIP_FW_UPDATE)
    message(FATAL_ERROR "${_wisp_rule8}: Bluetooth enabled without "
      "CONFIG_WISP_EM9305_SKIP_FW_UPDATE=y.")
  endif()

  # Wisp's patches (third_party/ambiq/patches/, applied by scripts/setup.sh) compile the
  # EM9305 update, recovery and trim paths out of the HAL and force skip_fw_update = true in
  # every caller. Without them the fork reflashes the EM9305, so a BT build on an unpatched
  # tree stops here. `git apply --reverse --check` succeeds only if the exact patch is in.
  option(WISP_RULE8_TEST_UNPATCHED
    "TEST ONLY: skip the patch check so wisp-fw:test can show the post-build gate rejects an unpatched BT image"
    OFF)
  file(GLOB _wisp_patches ${CMAKE_CURRENT_LIST_DIR}/../third_party/ambiq/patches/*.patch)
  if(NOT _wisp_patches)
    message(FATAL_ERROR "${_wisp_rule8}: no EM9305 patches found in third_party/ambiq/patches/.")
  endif()
  foreach(_p ${_wisp_patches})
    get_filename_component(_name ${_p} NAME)
    if(_name MATCHES "^zephyr-")
      set(_dir ${ZEPHYR_BASE})
    elseif(_name MATCHES "^hal_ambiq-")
      set(_dir ${ZEPHYR_HAL_AMBIQ_MODULE_DIR})
    else()
      message(FATAL_ERROR "${_wisp_rule8}: patch ${_name} names no known west project.")
    endif()
    execute_process(
      COMMAND git -C ${_dir} apply --reverse --check ${_p}
      RESULT_VARIABLE _rc OUTPUT_QUIET ERROR_QUIET)
    if(NOT _rc EQUAL 0)
      if(WISP_RULE8_TEST_UNPATCHED)
        message(WARNING "${_wisp_rule8}: TEST ONLY build without ${_name}; the post-build "
          "gate must reject this image.")
      else()
        message(FATAL_ERROR "${_wisp_rule8}: EM9305 patch missing: ${_name} is not applied "
          "to ${_dir}. Run `pnpm nx run wisp-fw:setup`.")
      endif()
    endif()
  endforeach()
  # Past this point scripts/check_rule8.py proves the result on the linked image: the
  # compiled driver has no update path, every caller forces skip_fw_update, and neither the
  # EM9305 image nor the update / recovery / NVM-write functions are linked.
endif()
