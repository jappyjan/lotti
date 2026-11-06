#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Recovery step 0. Run: uv run --with pyserial==3.5 apps/wisp-recovery/step0.py --plan"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wisp_case.step0 import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
