#!/bin/bash
set -euo pipefail

SOURCECODEURL="${SOURCECODEURL:-}"
PKGNAME="${PKGNAME:-}"
PACKAGE_PRESET="${PACKAGE_PRESET:-custom}"
BOARD="${BOARD:-}"
SDK_URL="${SDK_URL:-}"
SDK_SHA256="${SDK_SHA256:-}"
EMAIL=${EMAIL:-"aa@163.com"}
PASSWORD="${PASSWORD:-}"

if [ "$PACKAGE_PRESET" = "tailscale" ]; then
    SOURCECODEURL=""
    PKGNAME="tailscale"
elif [ "$PACKAGE_PRESET" != "custom" ]; then
    echo "ERROR: unknown package preset: $PACKAGE_PRESET"
    exit 1
fi

if [ -z "$BOARD" ]; then
    echo "ERROR: BOARD is required"
    exit 1
fi

if [ -z "$PKGNAME" ]; then
    echo "ERROR: PKGNAME is required when package preset is custom"
    exit 1
fi

echo SOURCECODEURL: "$SOURCECODEURL"
echo PKGNAME: "$PKGNAME"
echo PACKAGE_PRESET: "$PACKAGE_PRESET"
echo BOARD: "$BOARD"
echo EMAIL: "$EMAIL"

WORKDIR="$(pwd)"

# 使用预编译 SDK，依赖精简到现代 Ubuntu 能装上的包
sudo -E apt-get update
sudo -E apt-get install -y \
    build-essential git gawk gettext unzip wget rsync file python3 \
    libncurses-dev zlib1g-dev libssl-dev xsltproc xz-utils zstd

git config --global user.email "${EMAIL}"
git config --global user.name "aa"
[ -n "${PASSWORD}" ] && git config --global user.password "${PASSWORD}"

# 下载所有要编译的插件源码（SOURCECODEURL 可填多个仓库地址，空格分隔）
if [ -n "$SOURCECODEURL" ]; then
    mkdir -p "${WORKDIR}/buildsource"
    cd "${WORKDIR}/buildsource"
    for url in $SOURCECODEURL; do
        echo ">>> cloning $url"
        git clone "$url"
    done
    cd "${WORKDIR}"
fi

# ---------------- SDK 下载函数 ----------------
extract_sdk() {
    local archive="$1"
    mkdir -p "${WORKDIR}/openwrt-sdk"

    case "$(file -b "$archive")" in
        *XZ*)
            tar -Jxf "$archive" -C "${WORKDIR}/openwrt-sdk" --strip-components=1
            ;;
        *Zstandard*)
            tar --zstd -xf "$archive" -C "${WORKDIR}/openwrt-sdk" --strip-components=1
            ;;
        *gzip*)
            tar -zxf "$archive" -C "${WORKDIR}/openwrt-sdk" --strip-components=1
            ;;
        *)
            echo "ERROR: unsupported SDK archive format: $(file -b "$archive")"
            exit 1
            ;;
    esac
}

download_sdk() {
    local url="$1"
    local expected_sha256="${2:-}"
    local archive="${WORKDIR}/openwrt-sdk.archive"

    wget -q --show-progress -O "$archive" "$url"
    if [ -n "$expected_sha256" ]; then
        echo "${expected_sha256}  ${archive}" | sha256sum -c -
    fi
    extract_sdk "$archive"
}

x86_sdk_get() {
    download_sdk \
        "https://downloads.openwrt.org/releases/21.02.3/targets/x86/64/openwrt-sdk-21.02.3-x86-64_gcc-8.4.0_musl.Linux-x86_64.tar.xz"
}

# Linksys WRT32X = mvebu / cortexa9，内核 6.6 对应官方 24.10 版本
# 注意：24.10 的 SDK 是 .tar.zst（zstd 压缩），不是 .tar.xz
wrt32x_sdk_get() {
    download_sdk \
        "https://downloads.openwrt.org/releases/24.10.0/targets/mvebu/cortexa9/openwrt-sdk-24.10.0-mvebu-cortexa9_gcc-13.3.0_musl_eabi.Linux-x86_64.tar.zst"
}

# NanoPi R4SE 使用 rockchip/armv8，ipk 架构为 aarch64_generic。
# 截图中的 FriendlyWrt R23.7.7 是 2023 年 7 月的开发快照，不是 OpenWrt
# 正式版本号。默认使用时间和工具链最接近的 23.05.0-rc2 SDK。
# 它适合编译 tailscale 等用户态包；kmod 必须改用与路由器内核 ABI 完全
# 一致的 FriendlyWrt SDK，并通过工作流的 sdk_url/sdk_sha256 传入。
r4se_sdk_get() {
    local default_url
    local default_sha256

    default_url="https://downloads.openwrt.org/releases/23.05.0-rc2/targets/rockchip/armv8/openwrt-sdk-23.05.0-rc2-rockchip-armv8_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
    default_sha256="3bc93674f741a3601ecebc78a7bda285e20ad4d30ee5b4e184db9da3176a240b"

    if [ -n "$SDK_URL" ]; then
        echo ">>> using custom R4SE SDK: $SDK_URL"
        download_sdk "$SDK_URL" "$SDK_SHA256"
    else
        echo ">>> using OpenWrt 23.05.0-rc2 rockchip/armv8 SDK"
        download_sdk "$default_url" "$default_sha256"
    fi
}

case "$BOARD" in
    "R4SE")   r4se_sdk_get ;;
    "X86")    x86_sdk_get ;;
    "WRT32X") wrt32x_sdk_get ;;
    *) echo "Unsupported board: $BOARD"; exit 1 ;;
esac

cd "${WORKDIR}/openwrt-sdk"

# 更新官方 feeds（仅用于解决依赖，不挂本地 src-link，避免重名冲突）
./scripts/feeds update -a
./scripts/feeds install -a

# 把本地克隆的每个源码包，按其 Makefile 里的真实 PKG_NAME 直接复制进 package/。
# tailscale 预设不克隆上游源码，而是直接使用 SDK 固定版本的 packages feed。
if [ -d "${WORKDIR}/buildsource" ]; then
    for d in "${WORKDIR}"/buildsource/*/; do
        [ -f "${d}Makefile" ] || continue
        name="$(sed -n 's/^PKG_NAME[[:space:]]*:*=[[:space:]]*//p' "${d}Makefile" | head -n1 | tr -d '[:space:]')"
        [ -n "$name" ] || name="$(basename "$d")"
        echo ">>> package: $name  <=  $d"
        rm -rf "package/$name"
        cp -r "${d%/}" "package/$name"
        rm -rf "package/$name/.git"
    done
fi

# ---------------- 目标平台配置 ----------------
case "$BOARD" in
    "R4SE")
        cat >> .config <<EOF
CONFIG_TARGET_rockchip=y
CONFIG_TARGET_rockchip_armv8=y
CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r4s=y
EOF
        ;;
    "X86")
        cat >> .config <<EOF
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
EOF
        ;;
    "WRT32X")
        cat >> .config <<EOF
CONFIG_TARGET_mvebu=y
CONFIG_TARGET_mvebu_cortexa9=y
CONFIG_TARGET_mvebu_cortexa9_DEVICE_linksys_wrt32x=y
EOF
        ;;
esac

make defconfig

resolve_package_dir() {
    local pkg="$1"
    local candidate

    if [ -d "package/$pkg" ]; then
        echo "package/$pkg"
        return 0
    fi

    for candidate in package/feeds/*/"$pkg"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

# 编译所有指定插件（PKGNAME 可填多个包名，空格分隔）
for pkg in $PKGNAME; do
    if ! package_dir="$(resolve_package_dir "$pkg")"; then
        echo "ERROR: 找不到包 $pkg；请检查 PKGNAME，或确认它存在于当前 SDK 的 feeds 中"
        find package -maxdepth 4 -type d -iname "*${pkg}*" -print || true
        exit 1
    fi
    echo ">>> compiling $pkg from $package_dir"
    make V=s "${package_dir}/compile"
done

# 收集编译产物
find bin -type f -name "*.ipk" -exec ls -lh {} \;
find bin -type f -name "*.ipk" -exec cp -f {} "${WORKDIR}" \;
