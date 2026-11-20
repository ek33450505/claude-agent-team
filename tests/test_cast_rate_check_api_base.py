"""ANTHROPIC_API_BASE allowlist in scripts/cast-rate-check.py (authority parse)."""
import importlib.util
import os
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cast-rate-check.py"


def _load(base):
    old = os.environ.get("ANTHROPIC_API_BASE")
    os.environ["ANTHROPIC_API_BASE"] = base
    try:
        spec = importlib.util.spec_from_file_location("cast_rate_check_under_test", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        if old is None:
            del os.environ["ANTHROPIC_API_BASE"]
        else:
            os.environ["ANTHROPIC_API_BASE"] = old


class ApiBaseAllowlist(unittest.TestCase):
    def test_rejects(self):
        for bad in (
            "https://api.anthropic.com:x@evil.example/v1",
            "https://api.anthropic.com@evil.example",
            "https://localhost:8443@evil.example",
            "https://api.anthropic.com:/x",
            "https://api.anthropic.com:99999999",
            "https://api.anthropic.com.evil.example",
            "http://api.anthropic.com",
            "https://API.ANTHROPIC.COM",
            "https://Localhost:8443",
            "HTTPS://api.anthropic.com",
            "https://api.anthropic.com/x y",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    _load(bad)

    def test_accepts(self):
        for good in (
            "https://api.anthropic.com",
            "https://api.anthropic.com/v1",
            "https://localhost:8443",
            "https://localhost:8443/v1",
        ):
            with self.subTest(good=good):
                self.assertEqual(_load(good).API_BASE, good)


if __name__ == "__main__":
    unittest.main()
