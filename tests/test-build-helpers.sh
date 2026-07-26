#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

(
    DEVICE=R4SE
    FIRMWARE_VERSION=R25.8.8
    KERNEL_VERSION=6.12.42
    PACKAGE_NAMES="foo,bar"
    SOURCE_URL=https://github.com/example/repo
    SOURCE_REF=v1.2.3
    # shellcheck source=../build.sh
    source ./build.sh
    require_inputs
    [[ "${REQUESTED_PACKAGES[*]}" == "foo bar" ]]
)

if (
    DEVICE=R4SE
    FIRMWARE_VERSION=R25.8.8
    KERNEL_VERSION=6.12.42
    PACKAGE_NAMES="foo;bar"
    # shellcheck source=../build.sh
    source ./build.sh
    require_inputs
); then
    echo "invalid package name unexpectedly passed validation" >&2
    exit 1
fi

(
    DEVICE=R4SE
    FIRMWARE_VERSION=R25.8.8
    KERNEL_VERSION=6.12.42
    PACKAGE_NAMES="tailscale tailscaled"
    # shellcheck source=../build.sh
    source ./build.sh

    test_sdk="$(mktemp -d)"
    trap 'rm -rf -- "$test_sdk"' EXIT
    SDK_DIR="$test_sdk"
    mkdir -p "$SDK_DIR/package/feeds/packages/tailscale"
    cat >"$SDK_DIR/package/feeds/packages/tailscale/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
define Package/tailscale
endef
define Package/tailscaled
endef
$(eval $(call BuildPackage,tailscale))
$(eval $(call BuildPackage,tailscaled))
EOF
    cd "$SDK_DIR"
    [[ "$(resolve_package_directory tailscale)" == "package/feeds/packages/tailscale" ]]
    [[ "$(resolve_package_directory tailscaled)" == "package/feeds/packages/tailscale" ]]
)

echo "build helper tests: OK"
