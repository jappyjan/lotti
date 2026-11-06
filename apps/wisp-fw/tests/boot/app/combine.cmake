# SPDX-License-Identifier: MIT
# OUT = BOOT padded with 0xFF to 64 KiB (Wisp Boot's slot [0x438000, 0x448000)) + APP.
# APP=ERASED stands for 4 KiB of 0xFF (an erased app slot).
file(READ ${BOOT} boot HEX)
string(LENGTH "${boot}" n)
math(EXPR bytes "${n} / 2")
if(bytes GREATER 65536)
  message(FATAL_ERROR "Wisp Boot is ${bytes} bytes, its slot is 65536")
endif()
math(EXPR pad "65536 - ${bytes}")
string(REPEAT "ff" ${pad} padding)
if(APP STREQUAL "ERASED")
  string(REPEAT "ff" 4096 app)
else()
  file(READ ${APP} app HEX)
endif()
file(WRITE ${OUT}.hex "${boot}${padding}${app}")
# hex -> binary
execute_process(COMMAND python3 -c "import sys;open(sys.argv[2],'wb').write(bytes.fromhex(open(sys.argv[1]).read()))" ${OUT}.hex ${OUT} RESULT_VARIABLE r)
if(NOT r EQUAL 0)
  message(FATAL_ERROR "combine failed")
endif()
file(REMOVE ${OUT}.hex)
