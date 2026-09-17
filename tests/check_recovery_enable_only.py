#!/usr/bin/env python3
"""Source contract: recovery may enable a display, but must never disable one.

The M3 0.3.2 report showed successful initial enables followed by optional
disable/enable cycles whose final commits failed with 1001 on every retry.
This check prevents that destructive recovery step from being reintroduced;
it is not a replacement for a WindowServer or physical-display test.
"""

from pathlib import Path
import re
import unittest


class RecoveryEnableOnlyTests(unittest.TestCase):
    def test_every_recovery_layout_write_enables_the_display(self):
        source = (Path(__file__).resolve().parents[1] / "Sources" / "DisplayRecovery.swift").read_text()
        calls = re.findall(r"\.configureEnabled\(([^)]*)\)", source)
        self.assertTrue(calls, "Expected a recovery layout-enable operation")
        for arguments in calls:
            self.assertEqual(
                arguments.rsplit(",", 1)[-1].strip(),
                "true",
                "Recovery must only enable; a configurable enable/disable write can blank a restored screen",
            )


if __name__ == "__main__":
    unittest.main()
