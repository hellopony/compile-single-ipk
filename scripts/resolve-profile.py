#!/usr/bin/env python3
"""Resolve a device/firmware/kernel selection into trusted shell variables."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def shell_line(name: str, value: object) -> str:
    if isinstance(value, bool):
        rendered = "true" if value else "false"
    elif isinstance(value, list):
        rendered = "\n".join(str(item) for item in value)
    elif value is None:
        rendered = ""
    else:
        rendered = str(value)
    return f"{name}={shlex.quote(rendered)}"


def normalize_firmware(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip()).casefold()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles", required=True, type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--firmware", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--custom-sdk-url", default="")
    parser.add_argument("--custom-sdk-sha256", default="")
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    firmware_value = args.firmware.strip()
    kernel_value = args.kernel.strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ +()-]*", firmware_value):
        fail("firmware version contains unsupported characters")
    if not re.fullmatch(r"[0-9][A-Za-z0-9._+-]*", kernel_value):
        fail("kernel version contains unsupported characters")

    data = json.loads(args.profiles.read_text(encoding="utf-8"))
    devices = data.get("devices", {})
    profiles = data.get("profiles", [])

    if args.device not in devices:
        fail(
            f"unsupported device {args.device!r}; choose one of: "
            + ", ".join(sorted(devices))
        )

    device = devices[args.device]
    wanted_firmware = normalize_firmware(firmware_value)
    matches = []
    for profile in profiles:
        if profile.get("device") != args.device:
            continue
        names = [profile.get("firmware_version", ""), *profile.get("firmware_aliases", [])]
        if wanted_firmware in {normalize_firmware(name) for name in names if name}:
            matches.append(profile)

    custom_url = args.custom_sdk_url.strip()
    custom_sha = args.custom_sdk_sha256.strip().lower()
    if custom_url:
        if not custom_url.startswith("https://"):
            fail("custom SDK URL must use HTTPS")
        if not re.fullmatch(r"[0-9a-f]{64}", custom_sha):
            fail("a 64-character SHA256 is required with a custom SDK URL")
    elif custom_sha:
        fail("custom SDK SHA256 was supplied without a custom SDK URL")

    if matches:
        profile = matches[0]
        if profile.get("status") != "ready":
            fail(
                f"profile {profile.get('id')} is not buildable yet: "
                f"{profile.get('notes', 'missing verified SDK metadata')}"
            )
        expected_kernel = str(profile.get("kernel_version", "")).strip()
        if expected_kernel and kernel_value != expected_kernel:
            fail(
                f"kernel mismatch for {profile.get('id')}: expected "
                f"{expected_kernel}, got {kernel_value}"
            )
        profile_id = profile["id"]
        allow_kmods = bool(profile.get("allow_kmods", False))
        sdk_url = profile.get("sdk_url", "")
        sdk_sha = profile.get("sdk_sha256", "")
        kernel_abi = profile.get("kernel_abi", "")
        source_repo = profile.get("source_repo", "")
        source_commit = profile.get("source_commit", "")
        base_openwrt = profile.get("base_openwrt_version", profile["firmware_version"])
        notes = profile.get("notes", "")
    elif custom_url:
        if not device.get("custom_sdk_supported", False):
            fail(
                f"{args.device} cannot use an unregistered custom SDK until its "
                "target and package architecture are verified"
            )
        safe_firmware = re.sub(r"[^a-z0-9._-]+", "-", firmware_value.casefold()).strip("-")
        profile_id = f"custom-{args.device.lower()}-{safe_firmware}"
        allow_kmods = False
        sdk_url = custom_url
        sdk_sha = custom_sha
        kernel_abi = ""
        source_repo = ""
        source_commit = ""
        base_openwrt = firmware_value
        notes = (
            "One-off custom SDK profile. Kernel modules are blocked because an "
            "exact kernel ABI was not registered."
        )
    else:
        available = [
            f"{item.get('firmware_version')} / kernel {item.get('kernel_version') or 'unknown'}"
            for item in profiles
            if item.get("device") == args.device
        ]
        fail(
            f"no registered profile for {args.device} firmware {firmware_value!r}. "
            f"Registered profiles: {', '.join(available) or 'none'}. "
            "Register the firmware in profiles/firmware-profiles.json, or provide "
            "an exact SDK URL and SHA256 for a userspace-only build."
        )

    if not sdk_url or not re.fullmatch(r"[0-9a-f]{64}", sdk_sha):
        fail(f"profile {profile_id} does not contain a verified SDK and SHA256")

    values = {
        "PROFILE_ID": profile_id,
        "PROFILE_DISPLAY_NAME": device.get("display_name", args.device),
        "PROFILE_BOARD_NAME": device.get("board_name", ""),
        "PROFILE_DEVICE": args.device,
        "PROFILE_FIRMWARE_VERSION": firmware_value,
        "PROFILE_BASE_OPENWRT_VERSION": base_openwrt,
        "PROFILE_KERNEL_VERSION": kernel_value,
        "PROFILE_KERNEL_ABI": kernel_abi,
        "PROFILE_TARGET": device.get("target", ""),
        "PROFILE_SUBTARGET": device.get("subtarget", ""),
        "PROFILE_EXPECTED_ARCHES": device.get("expected_architectures", []),
        "PROFILE_TARGET_CONFIG": device.get("target_config", []),
        "PROFILE_SDK_URL": custom_url or sdk_url,
        "PROFILE_SDK_SHA256": custom_sha or sdk_sha,
        "PROFILE_SOURCE_REPO": source_repo,
        "PROFILE_SOURCE_COMMIT": source_commit,
        "PROFILE_ALLOW_KMODS": allow_kmods and not bool(custom_url),
        "PROFILE_NOTES": notes,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "\n".join(shell_line(name, value) for name, value in values.items()) + "\n",
        encoding="utf-8",
    )
    print(
        f"Resolved {profile_id}: {args.device} / {firmware_value} / "
        f"kernel {kernel_value}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
