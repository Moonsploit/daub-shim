#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$0")
VERSION=1

# Set custom temp directory with more space
export TMPDIR="$SCRIPT_DIR/../temp_build"
mkdir -p "$TMPDIR"

# Function to install dependencies
install_dependencies() {
    local missing_packages=()
    
    # Check which packages are missing
    for pkg in "$@"; do
        case "$pkg" in
            "gdisk")
                if ! command -v sgdisk >/dev/null 2>&1; then
                    missing_packages+=("gdisk")
                fi
                ;;
            "e2fsprogs")
                if ! command -v resize2fs >/dev/null 2>&1 || ! command -v tune2fs >/dev/null 2>&1; then
                    missing_packages+=("e2fsprogs")
                fi
                ;;
            "wget")
                if ! command -v wget >/dev/null 2>&1; then
                    missing_packages+=("wget")
                fi
                ;;
            "unzip")
                if ! command -v unzip >/dev/null 2>&1; then
                    missing_packages+=("unzip")
                fi
                ;;
            "curl")
                if ! command -v curl >/dev/null 2>&1; then
                    missing_packages+=("curl")
                fi
                ;;
            "numfmt")
                if ! command -v numfmt >/dev/null 2>&1; then
                    missing_packages+=("coreutils") # numfmt is part of coreutils
                fi
                ;;
            "util-linux")
                if ! command -v losetup >/dev/null 2>&1 || ! command -v fdisk >/dev/null 2>&1; then
                    missing_packages+=("util-linux")
                fi
                ;;
        esac
    done
    
    if [ ${#missing_packages[@]} -eq 0 ]; then
        return 0
    fi
    
    # Silent dependency installation
    if command -v apt >/dev/null 2>&1; then
        # Ubuntu/Debian
        apt update >/dev/null 2>&1 || return 1
        apt install -y "${missing_packages[@]}" >/dev/null 2>&1 || return 1
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora/RHEL/CentOS
        dnf install -y "${missing_packages[@]}" >/dev/null 2>&1 || return 1
    elif command -v yum >/dev/null 2>&1; then
        # Older RHEL/CentOS
        yum install -y "${missing_packages[@]}" >/dev/null 2>&1 || return 1
    elif command -v pacman >/dev/null 2>&1; then
        # Arch Linux
        pacman -Sy --noconfirm "${missing_packages[@]}" >/dev/null 2>&1 || return 1
    elif command -v zypper >/dev/null 2>&1; then
        # openSUSE
        zypper install -y "${missing_packages[@]}" >/dev/null 2>&1 || return 1
    else
        error "Could not detect package manager. Please install manually: ${missing_packages[*]}"
    fi
}

# Check and install required dependencies
check_dependencies() {
    # Required packages
    local required_packages=("gdisk" "e2fsprogs" "unzip" "util-linux" "numfmt")
    
    # Check for at least one download tool
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        required_packages+=("wget") # Prefer wget, but could be curl instead
    fi
    
    install_dependencies "${required_packages[@]}"
}

HOST_ARCH=$(lscpu | grep Architecture | awk '{print $2}')
if [ $HOST_ARCH == "x86_64" ]; then
  CGPT="$SCRIPT_DIR/bins/cgpt.x86-64"
  SFDISK="$SCRIPT_DIR/bins/sfdisk.x86-64"
else
  CGPT="$SCRIPT_DIR/bins/cgpt.aarch64"
  SFDISK="$SCRIPT_DIR/bins/sfdisk.aarch64"
fi

source $SCRIPT_DIR/functions.sh

echo "DAUB Shim Builder"
echo "Before building, huge credits to the MercuryWorkshop team for their work on wax,"
echo "daub-shim uses the kvs builder by kxtzownsu"

[ "$EUID" -ne 0 ] && error "Please run as root"

# Check and install dependencies before proceeding (silently)
check_dependencies

# Function to download shim
download_shim() {
    local board="$1"
    local primary_url="https://dl.cros.download/files/${board}/${board}.zip"
    local fallback_url="https://dl.blobfox.org/shims/ChromeOS/shims/Raw/${board}.zip"
    local output_file="${board}.zip"
    
    # Try primary URL first
    echo "Downloading shim from primary URL: $primary_url" >&2
    if command -v wget >/dev/null 2>&1; then
        if wget -q --show-progress -O "$output_file" "$primary_url"; then
            echo "Successfully downloaded from primary URL" >&2
        else
            echo "Primary URL failed, trying fallback: $fallback_url" >&2
            if wget -q --show-progress -O "$output_file" "$fallback_url"; then
                echo "Successfully downloaded from fallback URL" >&2
            else
                error "Failed to download shim for board: $board from both URLs"
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        if curl -L -o "$output_file" "$primary_url"; then
            echo "Successfully downloaded from primary URL" >&2
        else
            echo "Primary URL failed, trying fallback: $fallback_url" >&2
            if curl -L -o "$output_file" "$fallback_url"; then
                echo "Successfully downloaded from fallback URL" >&2
            else
                error "Failed to download shim for board: $board from both URLs"
            fi
        fi
    else
        error "Neither wget nor curl found. Please install one of them."
    fi
    
    # Extract the zip file
    if [ -f "$output_file" ]; then
        echo "extracting ${output_file}..." >&2
        unzip -q -o "$output_file" || error "Failed to extract shim zip file"
        
        # Look for bin files in the extracted contents
        local bin_file=$(find . -maxdepth 1 -name "*.bin" | head -1)
        if [ -n "$bin_file" ]; then
            # Delete the zip file to save space
            rm -f "$output_file"
            echo "$(basename "$bin_file")"  # Return just filename, not full path
        else
            error "No bin file found in the downloaded shim"
        fi
    else
        error "Downloaded file not found: $output_file"
    fi
}

# Check if first argument is a board name (download) or file path (existing shim)
if [ "$1" == "" ]; then
    error "Usage: $0 <board_name|shim_file>"
fi

# Determine if we need to download or use existing file
if [[ "$1" == *.* ]] && [ -f "$1" ]; then
    # Argument has a file extension and file exists, treat as file path
    IMG="$1"
    SHIM_SOURCE="local"
else
    # Argument is a board name or non-existent file, download the shim
    BOARD="$1"
    SHIM_SOURCE="download"
    
    # Create a temporary directory for download within our custom TMPDIR
    DOWNLOAD_DIR=$(mktemp -d -p "$TMPDIR")
    # Convert to absolute path by cd'ing to it and getting pwd
    cd "$DOWNLOAD_DIR" || error "Failed to enter download directory"
    DOWNLOAD_DIR=$(pwd)
    cd - >/dev/null

    # Download and extract the shim
    cd "$DOWNLOAD_DIR" || error "Failed to enter download directory: $DOWNLOAD_DIR"
    IMG_FILE=$(download_shim "$BOARD")
    IMG="$DOWNLOAD_DIR/$IMG_FILE"

    if [ ! -f "$IMG" ]; then
        error "Downloaded shim file not found: $IMG"
    fi

    cd - >/dev/null
fi

# Stateful is REALLY small, only about 45K with a full one.
STATE_SIZE=$((1 * 1024 * 1024)) # 1MiB
STATE_MNT="$(mktemp -d)"
ROOT_MNT="$(mktemp -d)"
LOOPDEV="$(losetup -f)"

# Verify the image file exists and is accessible
if [ ! -f "$IMG" ]; then
    error "Image file not found: $IMG"
fi

#we need this before we re-create stateful
STATE_START=$("$CGPT" show "$IMG" | grep "STATE" | awk '{print $1}')
suppress shrink_partitions "$IMG"
losetup -P "$LOOPDEV" "$IMG"
enable_rw_mount "${LOOPDEV}p3"

log "Correcting GPT errors.."
suppress fdisk "$LOOPDEV" <<EOF
w
EOF

inject_root
safesync

shrink_root
safesync

create_stateful
safesync

inject_stateful
safesync

umount_all
safesync

squash_partitions "$LOOPDEV"
safesync

# Always enable RW mount (anti-skid removed)
enable_rw_mount "${LOOPDEV}p3"

cleanup
safesync

truncate_image "$IMG"
safesync

# If we downloaded the shim, move the final image to current directory
if [ "$SHIM_SOURCE" = "download" ]; then
    FINAL_IMG="daub_${BOARD}.bin"
    mv "$IMG" "$FINAL_IMG"
    # Clean up download directory
    rm -rf "$DOWNLOAD_DIR"
    log "Final image saved as $FINAL_IMG"
else
    log "Final image saved as $IMG"
fi

# Silent cleanup of temp_build directory
rm -rf "$TMPDIR" 2>/dev/null

log "Done building DAUB!"
trap - EXIT
