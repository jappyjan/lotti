#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""W18 (patched bootloader + case loader). Run: python3 -I apps/wisp-recovery/w18.py bootloader-plan --side left"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wisp_w18.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
