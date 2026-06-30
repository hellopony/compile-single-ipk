#!/bin/bash
set -e

echo SOURCECODEURL: "$SOURCECODEURL"
echo PKGNAME: "$PKGNAME"
echo BOARD: "$BOARD"
EMAIL=${EMAIL:-"aa@163.com"}
echo EMAIL: "$EMAIL"

WORKDIR="$(pwd)"

# 使用预编译 SDK，依赖精简到现代 Ubuntu 能装上的包
sudo -E apt-get update
sudo -E apt-get install -y \
    build-essential git gawk gettext unzip wget rsync file python3 \
    libncurses-dev zlib1g-dev libssl-dev xsltproc zstd

git config --global user.email "${EMAIL}"
git config --global user.name "aa"
[ -n "${PASSWORD}" ] && git config --global user.password "${PASSWORD}"

# 下载所有要编译的插件源码（SOURCECODEURL 可填多个仓库地址，空格分隔）
mkdir -p "${WORKDIR}/buildsource"
cd "${WORKDIR}/buildsource"
for url in $SOURCECODEURL; do
    echo ">>> cloning $url"
    git clone "$url"
done
cd "${WORKDIR}"

# ---------------- SDK 下载函数 ----------------
x86_sdk_get() {
    wget -q -O openwrt-sdk.tar.xz \
        https://downloads.openwrt.org/releases/21.02.3/targets/x86/64/openwrt-sdk-21.02.3-x86-64_gcc-8.4.0_musl.Linux-x86_64.tar.xz
    mkdir -p "${WORKDIR}/openwrt-sdk"
    tar -Jxf openwrt-sdk.tar.xz -C "${WORKDIR}/openwrt-sdk" --strip-components=1
}

# Linksys WRT32X = mvebu / cortexa9，内核 6.6 对应官方 24.10 版本
# 注意：24.10 的 SDK 是 .tar.zst（zstd 压缩），不是 .tar.xz
wrt32x_sdk_get() {
    wget -q -O openwrt-sdk.tar.zst \
        https://downloads.openwrt.org/releases/24.10.0/targets/mvebu/cortexa9/openwrt-sdk-24.10.0-mvebu-cortexa9_gcc-13.3.0_musl_eabi.Linux-x86_64.tar.zst
    mkdir -p "${WORKDIR}/openwrt-sdk"
    tar --zstd -xf openwrt-sdk.tar.zst -C "${WORKDIR}/openwrt-sdk" --strip-components=1
}

case "$BOARD" in
    "X86")    x86_sdk_get ;;
    "WRT32X") wrt32x_sdk_get ;;
    *) echo "Unsupported board: $BOARD"; exit 1 ;;
esac

cd "${WORKDIR}/openwrt-sdk"

# 更新官方 feeds（仅用于解决依赖，不挂本地 src-link，避免重名冲突）
./scripts/feeds update -a
./scripts/feeds install -a

# 把本地克隆的每个源码包，按其 Makefile 里的真实 PKG_NAME 直接复制进 package/
for d in "${WORKDIR}"/buildsource/*/; do
    [ -f "${d}Makefile" ] || continue
    name="$(sed -n 's/^PKG_NAME[[:space:]]*:*=[[:space:]]*//p' "${d}Makefile" | head -n1 | tr -d '[:space:]')"
    [ -n "$name" ] || name="$(basename "$d")"
    echo ">>> package: $name  <=  $d"
    rm -rf "package/$name"
    cp -r "${d%/}" "package/$name"
    rm -rf "package/$name/.git"
done

# ---------------- 目标平台配置 ----------------
case "$BOARD" in
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

# 编译所有指定插件（PKGNAME 可填多个包名，空格分隔）
for pkg in $PKGNAME; do
    if [ ! -d "package/$pkg" ]; then
        echo "ERROR: package/$pkg 不存在，检查 PKGNAME 是否等于 Makefile 里的 PKG_NAME"
        ls -1 package/ | grep -i vlmcsd || true
        exit 1
    fi
    echo ">>> compiling $pkg"
    make V=s "package/$pkg/compile"
done

# 收集编译产物
find bin -type f -name "*.ipk" -exec ls -lh {} \;
find bin -type f -name "*.ipk" -exec cp -f {} "${WORKDIR}" \;
