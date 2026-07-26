#!/usr/bin/env bash
set -euo pipefail

DEVICE="${DEVICE:-${BOARD:-}}"
FIRMWARE_VERSION="${FIRMWARE_VERSION:-}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
PACKAGE_NAMES="${PACKAGE_NAMES:-${PKGNAME:-}}"
SOURCE_URL="${SOURCE_URL:-${SOURCECODEURL:-}}"
SOURCE_REF="${SOURCE_REF:-}"
PACKAGE_SUBDIR="${PACKAGE_SUBDIR:-}"
CUSTOM_SDK_URL="${CUSTOM_SDK_URL:-${SDK_URL:-}}"
CUSTOM_SDK_SHA256="${CUSTOM_SDK_SHA256:-${SDK_SHA256:-}}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_FILE="${WORKDIR}/profiles/firmware-profiles.json"
PROFILE_ENV="${WORKDIR}/.resolved-profile.env"
SDK_DIR="${WORKDIR}/openwrt-sdk"
SOURCE_DIR="${WORKDIR}/buildsource"
OUTPUT_DIR="${WORKDIR}/ipk-output"
SDK_ARCHIVE="${WORKDIR}/openwrt-sdk.archive"
BUILD_MARKER="${WORKDIR}/.ipk-build-start"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

trim_and_split() {
    tr ',\r\n\t' '    ' <<<"$1" | xargs
}

validate_package_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9+_.@-]*$ ]] ||
        die "invalid OpenWrt package name: $1"
}

validate_source_subdir() {
    local subdir="$1"
    [[ -n "$subdir" ]] || return 0
    [[ "$subdir" != /* && "$subdir" != *".."* ]] ||
        die "package subdirectory must be a relative path without '..': $subdir"
}

require_inputs() {
    [[ -n "$DEVICE" ]] || die "DEVICE is required"
    [[ -n "$FIRMWARE_VERSION" ]] || die "FIRMWARE_VERSION is required"
    [[ -n "$KERNEL_VERSION" ]] || die "KERNEL_VERSION is required"
    [[ -n "$PACKAGE_NAMES" ]] || die "PACKAGE_NAMES is required"

    if [[ -n "$SOURCE_URL" && "$SOURCE_URL" != https://* ]]; then
        die "SOURCE_URL must use HTTPS"
    fi
    if [[ -n "$SOURCE_REF" ]] &&
        [[ ! "$SOURCE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/@+-]*$ ]]; then
        die "SOURCE_REF contains unsupported characters"
    fi

    local normalized
    normalized="$(trim_and_split "$PACKAGE_NAMES")"
    [[ -n "$normalized" ]] || die "no package names were supplied"
    read -r -a REQUESTED_PACKAGES <<<"$normalized"
    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        validate_package_name "$package_name"
    done

    normalized="$(trim_and_split "$PACKAGE_SUBDIR")"
    PACKAGE_SUBDIRS=()
    if [[ -n "$normalized" ]]; then
        read -r -a PACKAGE_SUBDIRS <<<"$normalized"
        for subdir in "${PACKAGE_SUBDIRS[@]}"; do
            validate_source_subdir "$subdir"
        done
    fi
}

resolve_profile() {
    python3 "${WORKDIR}/scripts/resolve-profile.py" \
        --profiles "$PROFILE_FILE" \
        --device "$DEVICE" \
        --firmware "$FIRMWARE_VERSION" \
        --kernel "$KERNEL_VERSION" \
        --custom-sdk-url "$CUSTOM_SDK_URL" \
        --custom-sdk-sha256 "$CUSTOM_SDK_SHA256" \
        --output "$PROFILE_ENV"

    # The generated file contains only trusted values read from the repository's
    # profile registry, plus shell-quoted workflow inputs.
    # shellcheck disable=SC1090
    source "$PROFILE_ENV"

    echo "Profile:      $PROFILE_ID"
    echo "Device:       $PROFILE_DISPLAY_NAME"
    echo "Firmware:     $PROFILE_FIRMWARE_VERSION"
    echo "Kernel:       $PROFILE_KERNEL_VERSION"
    echo "Target:       $PROFILE_TARGET/$PROFILE_SUBTARGET"
    echo "Architecture: $(tr '\n' ' ' <<<"$PROFILE_EXPECTED_ARCHES")"
    echo "Allow kmods:  $PROFILE_ALLOW_KMODS"
}

prepare_workspace() {
    rm -rf -- "$SDK_DIR" "$SOURCE_DIR" "$OUTPUT_DIR"
    rm -f -- "$SDK_ARCHIVE" "$PROFILE_ENV" "$BUILD_MARKER"
    mkdir -p "$SDK_DIR" "$OUTPUT_DIR"
}

install_host_dependencies() {
    sudo -E apt-get update
    sudo -E apt-get install -y \
        build-essential ca-certificates file gawk gettext git libncurses-dev \
        libssl-dev python3 python3-dev python3-pyelftools python3-setuptools \
        rsync swig unzip wget xz-utils xsltproc zlib1g-dev zstd

    python3 -c 'import elftools' ||
        die "python3-pyelftools was installed, but Python cannot import elftools"
}

extract_sdk() {
    local archive="$1"
    local archive_type
    archive_type="$(file -b "$archive")"

    case "$archive_type" in
        *XZ*)
            tar -Jxf "$archive" -C "$SDK_DIR" --strip-components=1
            ;;
        *Zstandard*)
            tar --zstd -xf "$archive" -C "$SDK_DIR" --strip-components=1
            ;;
        *gzip*)
            tar -zxf "$archive" -C "$SDK_DIR" --strip-components=1
            ;;
        *)
            die "unsupported SDK archive format: $archive_type"
            ;;
    esac
}

download_sdk() {
    echo "Downloading verified SDK:"
    echo "  $PROFILE_SDK_URL"
    wget -q --show-progress -O "$SDK_ARCHIVE" "$PROFILE_SDK_URL"
    echo "${PROFILE_SDK_SHA256}  ${SDK_ARCHIVE}" | sha256sum -c -
    extract_sdk "$SDK_ARCHIVE"
    [[ -x "${SDK_DIR}/scripts/feeds" ]] ||
        die "the downloaded archive is not an OpenWrt SDK"
}

clone_source() {
    [[ -n "$SOURCE_URL" ]] || return 0

    mkdir -p "$SOURCE_DIR"
    if [[ -n "$SOURCE_REF" ]]; then
        git clone --filter=blob:none --no-checkout "$SOURCE_URL" "${SOURCE_DIR}/repo"
        git -C "${SOURCE_DIR}/repo" fetch --depth 1 origin "$SOURCE_REF"
        git -C "${SOURCE_DIR}/repo" checkout --detach FETCH_HEAD
    else
        git clone --depth 1 "$SOURCE_URL" "${SOURCE_DIR}/repo"
    fi
    git -C "${SOURCE_DIR}/repo" rev-parse HEAD >"${SOURCE_DIR}/source-commit.txt"
}

is_openwrt_package_makefile() {
    local makefile="$1"
    grep -Fq '$(TOPDIR)/rules.mk' "$makefile" &&
        grep -Eq '\$\(eval[[:space:]]+\$\(call[[:space:]]+BuildPackage' "$makefile"
}

copy_package_directory() {
    local source_path="$1"
    local index="$2"
    local base safe destination

    [[ -f "${source_path}/Makefile" ]] ||
        die "no Makefile found in package source directory: $source_path"
    is_openwrt_package_makefile "${source_path}/Makefile" ||
        die "not an OpenWrt package Makefile: ${source_path}/Makefile"

    base="$(basename "$source_path")"
    safe="$(tr -cs 'A-Za-z0-9._-' '-' <<<"$base" | sed 's/^-//;s/-$//')"
    destination="${SDK_DIR}/package/custom/${index}-${safe:-package}"
    mkdir -p "$(dirname "$destination")"
    cp -a "$source_path" "$destination"
    rm -rf -- "${destination}/.git"
    echo "Imported package source: ${source_path} -> ${destination#"$SDK_DIR/"}"
}

install_custom_package_sources() {
    [[ -n "$SOURCE_URL" ]] || return 0

    local repo="${SOURCE_DIR}/repo"
    local index=0
    local subdir makefile source_path

    if ((${#PACKAGE_SUBDIRS[@]} > 0)); then
        for subdir in "${PACKAGE_SUBDIRS[@]}"; do
            source_path="${repo}/${subdir%/}"
            [[ -d "$source_path" ]] ||
                die "package subdirectory does not exist in source repository: $subdir"
            index=$((index + 1))
            copy_package_directory "$source_path" "$index"
        done
    else
        while IFS= read -r -d '' makefile; do
            if is_openwrt_package_makefile "$makefile"; then
                index=$((index + 1))
                copy_package_directory "$(dirname "$makefile")" "$index"
            fi
        done < <(
            find "$repo" -path '*/.git' -prune -o -type f -name Makefile -print0
        )
    fi

    ((index > 0)) ||
        die "no OpenWrt package Makefile was found; set PACKAGE_SUBDIR explicitly"

    # Prefer the explicitly supplied source over an SDK feed package with the
    # same conventional directory name.
    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        find "${SDK_DIR}/package/feeds" -mindepth 2 -maxdepth 2 \
            -type l -name "$package_name" -delete 2>/dev/null || true
    done
}

prepare_sdk_feeds() {
    cd "$SDK_DIR"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

configure_sdk() {
    cd "$SDK_DIR"
    if [[ -n "$PROFILE_TARGET_CONFIG" ]]; then
        while IFS= read -r config_line; do
            [[ -n "$config_line" ]] && echo "$config_line" >>.config
        done <<<"$PROFILE_TARGET_CONFIG"
    fi

    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        echo "CONFIG_PACKAGE_${package_name}=m" >>.config
    done
    make defconfig
}

makefile_defines_package() {
    local makefile="$1"
    local package_name="$2"
    local declared_name

    if grep -Fq "Package/${package_name}" "$makefile" ||
        grep -Fq "BuildPackage,${package_name})" "$makefile"; then
        return 0
    fi

    declared_name="$(
        sed -n \
            's/^[[:space:]]*PKG_NAME[[:space:]]*:*=[[:space:]]*//p' \
            "$makefile" |
            head -n1 |
            tr -d '[:space:]'
    )"
    [[ "$declared_name" == "$package_name" ]]
}

resolve_package_directory() {
    local package_name="$1"
    local candidate makefile

    for candidate in \
        "package/${package_name}" \
        "package/custom/${package_name}" \
        package/feeds/*/"${package_name}"; do
        if [[ -f "${candidate}/Makefile" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    for candidate in package/custom package/feeds package; do
        [[ -d "$candidate" ]] || continue
        while IFS= read -r -d '' makefile; do
            if makefile_defines_package "$makefile" "$package_name"; then
                dirname "$makefile"
                return 0
            fi
        done < <(
            find -L "$candidate" -type f -name Makefile -print0 2>/dev/null
        )
    done

    return 1
}

compile_requested_packages() {
    cd "$SDK_DIR"
    declare -A build_directories=()
    local package_name package_dir

    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        if ! package_dir="$(resolve_package_directory "$package_name")"; then
            echo "Known custom package definitions:" >&2
            find package/custom -type f -name Makefile -print 2>/dev/null || true
            die "cannot find an OpenWrt package definition for: $package_name"
        fi
        build_directories["$package_dir"]=1
        echo "Resolved package $package_name -> $package_dir"
    done

    touch "$BUILD_MARKER"
    for package_dir in "${!build_directories[@]}"; do
        echo "Cleaning $package_dir"
        make "${package_dir}/clean"
        echo "Compiling $package_dir"
        make V=s "${package_dir}/compile"
    done
}

extract_ipk_control() {
    local ipk="$1"
    local temp_dir member
    temp_dir="$(mktemp -d "${WORKDIR}/ipk-control.XXXXXX")"

    (
        cd "$temp_dir"
        ar x "$ipk"
        member="$(find . -maxdepth 1 -type f -name 'control.tar.*' -print -quit)"
        [[ -n "$member" ]] || exit 2
        tar -xf "$member"
        [[ -f control ]] || exit 3
        cat control
    )
    local result=$?
    rm -rf -- "$temp_dir"
    return "$result"
}

architecture_is_allowed() {
    local architecture="$1"
    local expected

    [[ "$architecture" == "all" || "$architecture" == "noarch" ]] && return 0
    while IFS= read -r expected; do
        [[ -n "$expected" && "$architecture" == "$expected" ]] && return 0
    done <<<"$PROFILE_EXPECTED_ARCHES"
    return 1
}

write_manifest_header() {
    local source_commit=""
    [[ -f "${SOURCE_DIR}/source-commit.txt" ]] &&
        source_commit="$(<"${SOURCE_DIR}/source-commit.txt")"

    {
        echo "OpenWrt single-package build manifest"
        echo
        echo "Profile: ${PROFILE_ID}"
        echo "Device: ${PROFILE_DISPLAY_NAME}"
        echo "Board name: ${PROFILE_BOARD_NAME}"
        echo "Firmware: ${PROFILE_FIRMWARE_VERSION}"
        echo "Base OpenWrt: ${PROFILE_BASE_OPENWRT_VERSION}"
        echo "Kernel: ${PROFILE_KERNEL_VERSION}"
        echo "Kernel ABI: ${PROFILE_KERNEL_ABI:-not registered}"
        echo "Target: ${PROFILE_TARGET}/${PROFILE_SUBTARGET}"
        echo "Expected package architectures: $(tr '\n' ' ' <<<"$PROFILE_EXPECTED_ARCHES")"
        echo "SDK: ${PROFILE_SDK_URL}"
        echo "SDK SHA256: ${PROFILE_SDK_SHA256}"
        echo "Profile source: ${PROFILE_SOURCE_REPO:-not registered}"
        echo "Profile source commit: ${PROFILE_SOURCE_COMMIT:-not registered}"
        echo "Package source: ${SOURCE_URL:-SDK feeds}"
        echo "Package source ref: ${SOURCE_REF:-default branch/feed pin}"
        echo "Package source commit: ${source_commit:-not applicable}"
        echo "Package subdirectory: ${PACKAGE_SUBDIR:-auto-discovery/feed}"
        echo "Requested packages: ${REQUESTED_PACKAGES[*]}"
        echo "Kernel packages allowed: ${PROFILE_ALLOW_KMODS}"
        echo "Notes: ${PROFILE_NOTES}"
        echo
        echo "Artifacts:"
    } >"${OUTPUT_DIR}/build-manifest.txt"
}

write_install_check() {
    cat >"${OUTPUT_DIR}/check-before-install.sh" <<EOF
#!/bin/sh
set -eu

expected_board='${PROFILE_BOARD_NAME}'
expected_kernel='${PROFILE_KERNEL_VERSION}'
expected_arches='$(tr '\n' ' ' <<<"$PROFILE_EXPECTED_ARCHES") all noarch'

board="\$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' 2>/dev/null || true)"
kernel="\$(uname -r)"
architectures="\$(opkg print-architecture 2>/dev/null | awk '{print \$2}')"

[ -z "\$expected_board" ] || [ "\$board" = "\$expected_board" ] || {
    echo "ERROR: board mismatch: expected \$expected_board, got \${board:-unknown}" >&2
    exit 1
}
[ "\$kernel" = "\$expected_kernel" ] || {
    echo "ERROR: kernel mismatch: expected \$expected_kernel, got \$kernel" >&2
    exit 1
}

for expected in \$expected_arches; do
    echo "\$architectures" | grep -Fxq "\$expected" && {
        echo "Compatibility check passed for ${PROFILE_ID}."
        exit 0
    }
done

echo "ERROR: none of the expected package architectures are enabled: \$expected_arches" >&2
exit 1
EOF
    chmod +x "${OUTPUT_DIR}/check-before-install.sh"
}

collect_artifacts() {
    cd "$SDK_DIR"
    write_manifest_header

    declare -A selected_artifacts=()
    local package_name artifact control package architecture depends

    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        while IFS= read -r -d '' artifact; do
            selected_artifacts["$artifact"]=1
        done < <(
            find bin -type f -name "${package_name}_*.ipk" \
                -newer "$BUILD_MARKER" -print0
        )
    done

    ((${#selected_artifacts[@]} > 0)) ||
        die "compilation finished, but none of the requested IPKs were produced"

    for artifact in "${!selected_artifacts[@]}"; do
        control="$(extract_ipk_control "$(realpath "$artifact")")" ||
            die "cannot read IPK control metadata: $artifact"
        package="$(sed -n 's/^Package:[[:space:]]*//p' <<<"$control" | head -n1)"
        architecture="$(sed -n 's/^Architecture:[[:space:]]*//p' <<<"$control" | head -n1)"
        depends="$(sed -n 's/^Depends:[[:space:]]*//p' <<<"$control" | head -n1)"

        [[ -n "$package" && -n "$architecture" ]] ||
            die "IPK is missing Package or Architecture metadata: $artifact"

        case " ${REQUESTED_PACKAGES[*]} " in
            *" ${package} "*) ;;
            *) die "refusing unexpected package artifact: $package" ;;
        esac

        architecture_is_allowed "$architecture" ||
            die "architecture mismatch for $package: got $architecture; expected $(tr '\n' ' ' <<<"$PROFILE_EXPECTED_ARCHES") or all"

        if [[ "$PROFILE_ALLOW_KMODS" != "true" ]]; then
            case "$package" in
                kernel|kmod-*)
                    die "kernel package $package is blocked for profile $PROFILE_ID"
                    ;;
            esac
        fi

        cp -f "$artifact" "$OUTPUT_DIR/"
        {
            echo
            echo "- File: $(basename "$artifact")"
            echo "  Package: $package"
            echo "  Architecture: $architecture"
            echo "  Depends: ${depends:-none}"
            echo "  SHA256: $(sha256sum "$artifact" | awk '{print $1}')"
        } >>"${OUTPUT_DIR}/build-manifest.txt"
        echo "Selected artifact: $(basename "$artifact")"
    done

    for package_name in "${REQUESTED_PACKAGES[@]}"; do
        find "$OUTPUT_DIR" -maxdepth 1 -type f \
            -name "${package_name}_*.ipk" -print -quit | grep -q . ||
            die "requested output package was not produced: $package_name"
    done

    write_install_check
}

main() {
    require_inputs
    prepare_workspace
    resolve_profile
    install_host_dependencies
    download_sdk
    clone_source
    prepare_sdk_feeds
    install_custom_package_sources
    configure_sdk
    compile_requested_packages
    collect_artifacts
    echo "Build completed: ${OUTPUT_DIR}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
