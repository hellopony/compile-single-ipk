#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "scripts" / "resolve-profile.py"
PROFILES = ROOT / "profiles" / "firmware-profiles.json"


def resolve(*arguments: str, expected: int = 0) -> str:
    with tempfile.TemporaryDirectory() as temp_dir:
        output = Path(temp_dir) / "profile.env"
        result = subprocess.run(
            [
                sys.executable,
                str(RESOLVER),
                "--profiles",
                str(PROFILES),
                *arguments,
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != expected:
            raise AssertionError(
                f"expected exit {expected}, got {result.returncode}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return output.read_text(encoding="utf-8") if output.exists() else result.stderr


def main() -> int:
    r4se = resolve(
        "--device",
        "R4SE",
        "--firmware",
        "25.8.8",
        "--kernel",
        "6.12.42",
    )
    assert "PROFILE_ID=r4se-lede-r25.8.8" in r4se
    assert "PROFILE_ALLOW_KMODS=false" in r4se

    wrt32x = resolve(
        "--device",
        "WRT32X",
        "--firmware",
        "24.10.0",
        "--kernel",
        "6.6.73",
    )
    assert "PROFILE_ALLOW_KMODS=true" in wrt32x

    mismatch = resolve(
        "--device",
        "R4SE",
        "--firmware",
        "R25.8.8",
        "--kernel",
        "5.15.120",
        expected=1,
    )
    assert "kernel mismatch" in mismatch

    blocked = resolve(
        "--device",
        "GL-MT3600BE",
        "--firmware",
        "4.9.0",
        "--kernel",
        "1.0",
        expected=1,
    )
    assert "not buildable yet" in blocked

    custom = resolve(
        "--device",
        "R4SE",
        "--firmware",
        "R25.8.9",
        "--kernel",
        "6.12.50",
        "--custom-sdk-url",
        "https://example.com/sdk.tar.zst",
        "--custom-sdk-sha256",
        "a" * 64,
    )
    assert "PROFILE_ID=custom-r4se-r25.8.9" in custom
    assert "PROFILE_ALLOW_KMODS=false" in custom

    missing_checksum = resolve(
        "--device",
        "R4SE",
        "--firmware",
        "R25.8.9",
        "--kernel",
        "6.12.50",
        "--custom-sdk-url",
        "https://example.com/sdk.tar.zst",
        expected=1,
    )
    assert "SHA256 is required" in missing_checksum

    print("profile resolver tests: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
