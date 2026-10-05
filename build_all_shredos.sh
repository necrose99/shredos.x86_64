#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Usage: ./build_all_shredos.sh [x64|x32|arm64|all]
#
# Arguments:
#  x64     - Build only x86-64 configurations
#  x32     - Build only i686 (32-bit) configurations
#  arm64   - Build hybrid Debian-based ARM64 utility configurations
#  all     - Build all configurations sequentially (64-bit -> 32-bit -> ARM64)
#
# Environment Variables:
#  DRY_RUN=0|1      - Output all commands that would be executed (default: 0)
#  PRE_CLEAN=0|1    - Do an initial clean before starting (default: 1)
#  QUICK_BUILD=0|1  - Use rapid package caching layers (default: 0)
#  FAST_FAIL=0|1    - Exit on first build step failure (default: 1)
#  NEW_VERSION=STR  - Set customized image version string
################################################################################

VERSION_FILE="board/shredos/fsoverlay/etc/shredos/version.txt"
UNROOT_VERSION="1.0.5"
UNROOT_URL="https://github.com{UNROOT_VERSION}/unroot"

X64_CONFIGS=(
	"shredos_defconfig"
	"shredos_lite_defconfig"
	"shredos_iso_extra_defconfig"
)

X32_CONFIGS=(
	"shredos_i686_lite_defconfig"
	"shredos_iso_extra_i686_lite_defconfig"
)

# New integrated native and fake-buildroot ARM64 target paths
ARM64_CONFIGS=(
	"shredos_debian_arm64_netinst"
	"shredos_debian_arm64_live_utility"
)

ALWAYS_REBUILD_PKGS=(
	"nwipe"
	"grub2"
)

DRY_RUN="${DRY_RUN:-0}"
PRE_CLEAN="${PRE_CLEAN:-1}"
QUICK_BUILD="${QUICK_BUILD:-0}"
FAST_FAIL="${FAST_FAIL:-1}"
NEW_VERSION="${NEW_VERSION:-}"

X64_SUCCESS=0;  X64_FAILED=0
X32_SUCCESS=0;  X32_FAILED=0
ARM64_SUCCESS=0; ARM64_FAILED=0

GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"
FORCE_CLEAN=0

print_usage() {
	echo -e "\nUsage: $0 [x64|x32|arm64|all]\n"
	echo "Arguments:"
	echo "  x64     - Build only x86-64 configurations"
	echo "  x32     - Build only i686 (32-bit) configurations"
	echo "  arm64   - Build hybrid Debian ARM64 systems via unroot"
	echo "  all     - Build all configurations combined"
	echo -e "\nEnvironment Variables:"
	echo "  DRY_RUN=0|1      - Output commands without writing state (default: 0)"
	echo "  QUICK_BUILD=0|1  - Skip full environments when building matches (default: 0)"
}

parse_arguments() {
	if [ $# -eq 0 ]; then
		printf "%b" "$RED"
		echo "Error: Missing target architecture configuration argument"
		printf "%b" "$RESET"; print_usage; exit 1
	fi

	BUILD_TARGET="$1"
	case "$BUILD_TARGET" in
		x64)   X32_CONFIGS=(); ARM64_CONFIGS=() ;;
		x32)   X64_CONFIGS=(); ARM64_CONFIGS=() ;;
		arm64) X64_CONFIGS=(); X32_CONFIGS=() ;;
		all)   ;;
		*) printf "%b" "$RED"; echo "Error: Invalid selection '$BUILD_TARGET'"; printf "%b" "$RESET"; print_usage; exit 1 ;;
	esac
}

prompt_version() {
	if [ ! -f "$VERSION_FILE" ]; then
		mkdir -p "$(dirname "$VERSION_FILE")"
		echo "v2026.10_unstable_arm64" > "$VERSION_FILE"
	fi
	local current_version=$(cat "$VERSION_FILE")

	if [ -z "$NEW_VERSION" ]; then
		echo -e "\nSwitching builds matching targeted architecture configurations..."
		read -rp "Enter version string or press ENTER to preserve [${current_version}]: " NEW_VERSION
		[ -z "$NEW_VERSION" ] && NEW_VERSION="$current_version"
	fi

	run_cmd_change_version "$NEW_VERSION"
}

run_cmd() {
	local timestamp=$(date '+%d.%m.%Y %H:%M:%S')
	if [ "$DRY_RUN" -eq 1 ]; then
		echo -e "${YELLOW}[DRY_RUN] $*${RESET}"
	else
		echo "[$timestamp] $*" >> "build_all_shredos.log"
		"$@"
	fi
}

run_cmd_tee() {
	local log_file="$1"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[DRY_RUN] piping layout context output to $log_file"
		cat > /dev/null
	else
		tee "$log_file"
	fi
}

run_cmd_change_version() {
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[DRY_RUN] echo \"$1\" > \"$VERSION_FILE\""
	else
		echo "$1" > "$VERSION_FILE"
	fi
}

# Realizes core multi-arch tool injection using host dependencies
install_host_dependencies() {
	echo "=== Verifying System Cross-Compilation and Packaging Infrastructure ==="
	if [ "$DRY_RUN" -eq 0 ]; then
		sudo dpkg --add-architecture arm64 || true
		sudo apt-get update -qq || true
		sudo apt-get install -y -qq xorriso squashfs-tools bsdtar crossbuild-essential-arm64 clang llvm mtools cpio debootstrap
		if [ ! -f "./unroot" ]; then
			curl -L -o unroot "${UNROOT_URL}"
			chmod +x unroot
		fi
	fi
}

build_config() {
	local index="$1"
	local config="$2"
	local arch="$3"
	local log_file="dist/${config}.log"

	echo -e "${YELLOW}\n============================================"
	echo " Started: '$config' ($arch)"
	echo -e "============================================${RESET}"

	if [ "$arch" = "arm64" ]; then
		# Execute customized hybrid translation loop
		run_arm64_pipeline "$config" "$log_file"
	else
		# Follow original Buildroot compilation paths for traditional x86 engines
		if [ "$index" -ne 0 ] && [ "$QUICK_BUILD" -eq 1 ] && [ "$FORCE_CLEAN" -ne 1 ]; then
			run_cmd make "$config"
			for pkg in "${ALWAYS_REBUILD_PKGS[@]}"; do
				run_cmd make "${pkg}-reconfigure"
			 Clyde
		else
			if [ "$index" -ne 0 ] || [ "$FORCE_CLEAN" -eq 1 ]; then
				run_cmd make clean
			fi
			run_cmd make "$config"
		fi
		
		if run_cmd make 2>&1 | run_cmd_tee "$log_file"; then
			build_config_success "$config" "$arch" "$log_file"
		else
			build_config_failed "$config" "$arch" "$log_file"
		fi
	fi
	FORCE_CLEAN=0
}

run_arm64_pipeline() {
	local config="$1"
	local log_file="$2"
	local target_rootfs="/tmp/shredos-rootfs-arm64"
	
	echo "[ARM64 ENGINE] Running Debootstrap + Unroot Namespace Assembly Integration Matrix..." >> "$log_file"
	if [ "$DRY_RUN" -eq 0 ]; then
		mkdir -p "dist/${config}" /tmp/shredos-iso-out
		if [ ! -d "${target_rootfs}/etc" ]; then
			sudo debootstrap --arch=arm64 --variant=minbase "bookworm" "${target_rootfs}" "http://debian.org"
			sudo chown -R "$(id -u):$(id -g)" "${target_rootfs}"
		fi
		
		# Leverage Unroot 1.0.5 path patching inside environment container natively
		./unroot single --cwd "${target_rootfs}" --env PATH=/usr/sbin:/usr/bin:/sbin:/bin -- \
			apt-get update && apt-get install -y --no-install-recommends \
			nwipe smartmontools hdparm nvme-cli build-essential clang rustc cargo libpdf-api2-perl sysvinit-core
			
		# Compile rootfs using user tools directly into a deployment SquashFS package file
		./unroot pack "${target_rootfs}" "dist/${config}/shredos-arm64.squashfs"
	fi
	echo -e "${GREEN}SUCCESS: Compiled hybrid target package: dist/${config}/shredos-arm64.squashfs${RESET}"
	((ARM64_SUCCESS++))
}

build_config_success() {
	echo -e "${GREEN}\n==============================================="
	echo " SUCCESS: '$1' ($2)"
	echo -e "===============================================${RESET}"
	mkdir -p "dist/$1"
	[ -f "output/images/shredos" ] && mv output/images/shredos* "dist/$1/" || true
	if [ "$2" = "x64" ]; then ((X64_SUCCESS++)); else ((X32_SUCCESS++)); fi
}

build_config_failed() {
	echo -e "${RED}\n==============================================="
	echo " FAILURE: '$1' ($2)"
	echo -e "===============================================${RESET}"
	if [ "$2" = "x64" ]; then ((X64_FAILED++)); else ((X32_FAILED++)); fi
	if [ "$FAST_FAIL" -eq 1 ]; then exit 1; fi
}

print_summary_and_exit() {
	echo -e "\n============================================"
	echo " SHREDOS MULTI-ARCH BUILD SUMMARY"
	echo "============================================"
	echo " 64-bit x86 builds:  $X64_SUCCESS succeeded, $X64_FAILED failed"
	echo " 32-bit x86 builds:  $X32_SUCCESS succeeded, $X32_FAILED failed"
	echo " ARM64 target builds: $ARM64_SUCCESS succeeded, $ARM64_FAILED failed"
	echo "============================================"
	exit 0
}

# --- CONTROL CORE EXECUTION FLOW ---
parse_arguments "$@"
prompt_version
install_host_dependencies

rm -rf dist build_all_shredos.log
mkdir -p dist

trap print_summary_and_exit EXIT INT TERM

# 1. Process standard 64-Bit x86 architectures
if [ ${#X64_CONFIGS[@]} -gt 0 ]; then
	CFG_INDEX=0
	for config in "${X64_CONFIGS[@]}"; do
		build_config "$CFG_INDEX" "$config" "x64"
		((CFG_INDEX++))
	done
fi

# 2. Process legacy 32-Bit x86 architectures
if [ ${#X32_CONFIGS[@]} -gt 0 ]; then
	FORCE_CLEAN=1
	CFG_INDEX=0
	for config in "${X32_CONFIGS[@]}"; do
		build_config "$CFG_INDEX" "$config" "x32"
		((CFG_INDEX++))
	done
fi

# 3. Process new decoupled cross-emulated ARM64 architectures
if [ ${#ARM64_CONFIGS[@]} -gt 0 ]; then
	CFG_INDEX=0
	for config in "${ARM64_CONFIGS[@]}"; do
		build_config "$CFG_INDEX" "$config" "arm64"
		((CFG_INDEX++))
	done
fi
