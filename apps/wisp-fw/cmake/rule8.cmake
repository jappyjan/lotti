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
#                                              skip_fw_update left false (fork 89c8a36)
#   CONFIG_AMBIQ_COMPONENT_USE_BT           -> compiles am_devices_em9305.c (+ the image)
#   CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT-> evb board.c path: skip_fw_update = CONFIG_BT,
#                                              i.e. false when BT is off
#   CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM -> writes EM9305 NVM info page 2

set(_wisp_rule8 "WISP SAFETY RULE 8 (docs/wisp/safety.md)")

if(CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT)
  message(FATAL_ERROR "${_wisp_rule8}: CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT=y runs "
    "am_devices_em9305_init() with skip_fw_update=false when BT is off (EM9305 reflash).")
endif()

if(CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM)
  message(FATAL_ERROR "${_wisp_rule8}: CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM=y writes "
    "the EM9305 NVM info page.")
endif()

if(CONFIG_BT OR CONFIG_AMBIQ_COMPONENT_USE_BT)
  if(NOT CONFIG_WISP_BT_ALLOWED)
    message(FATAL_ERROR "${_wisp_rule8}: Bluetooth / the EM9305 driver is enabled but stays "
      "disabled until milestone M6 (CONFIG_WISP_BT_ALLOWED=n).")
  endif()
  if(NOT CONFIG_WISP_EM9305_SKIP_FW_UPDATE)
    message(FATAL_ERROR "${_wisp_rule8}: Bluetooth enabled without "
      "CONFIG_WISP_EM9305_SKIP_FW_UPDATE=y.")
  endif()
  # Past this point scripts/check_rule8.py still has to pass: every compiled
  # am_devices_em9305_callback_t must set skip_fw_update = true, and neither the EM9305
  # image nor the update/recovery functions may be linked. The unpatched fork fails both.
endif()
