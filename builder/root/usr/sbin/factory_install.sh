#!/bin/sh

# Function to dynamically get the booted kernel ID (2 or 4)
get_booted_kernnum() {
    # Compares the priority (P) of Kernel A (i 2) vs Kernel B (i 4).
    # The partition with the higher priority is considered the active boot.
    if [ $(cgpt show -n "$intdis" -i 2 -P) -gt $(cgpt show -n "$intdis" -i 4 -P) ]; then
        echo -n 2 # Kernel A is active
    else
        echo -n 4 # Kernel B is active
    fi
}

# Function to dynamically get the booted rootfs ID (3 or 5)
get_booted_rootnum() {
    # The rootfs is always the partition index immediately following its kernel.
    expr $(get_booted_kernnum) + 1
}

mountlvm(){
    vgchange -ay # activate all volume groups
    volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    echo "found volume group: $volgroup"
    mount "/dev/$volgroup/unencrypted" /stateful || {
        echo "couldn't mount p1 or lvm group. Please recover"
        return 1
    }
}


while true; do
    clear
    echo ""
    echo "    ██████╗  █████╗ ██╗    ██╗██████╗ "
    echo "    ██╔══██╗██╔══██╗██║    ██║██╔══██╗"
    echo "    ██║  ██║███████║██║    ██║██████╔╝"
    echo "    ██║  ██║██╔══██║██║    ██║██╔══██╗"
    echo "    ██████╔╝██║  ██║╚██████╔╝██████╔╝"
    echo "    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝"
    echo "  depthcharge automatic update blocking"
    echo "              found by zeglol"
    echo "      script mostly by HarryTarryJarry"
    echo ""

    echo "1) Block updates"
    echo "2) Bash shell"
    echo "3) Reboot"
    read -p "Choose option: " choice

    case $choice in
        1)
            # get_internal taken from https://github.com/applefritter-inc/BadApple-icarus
            get_internal() {
                # get_largest_cros_blockdev does not work in BadApple.
                local ROOTDEV_LIST=$(cgpt find -t rootfs)
                if [ -z "$ROOTDEV_LIST" ]; then
                    echo "Could not find root devices."
                    read -p "Press Enter to return to menu..."
                    return 1
                fi
                local device_type=$(echo "$ROOTDEV_LIST" | grep -oE 'blk0|blk1|nvme|sda' | head -n 1)
                case $device_type in
                "blk0")
                    intdis=/dev/mmcblk0
                    intdis_prefix="p"
                    ;;
                "blk1")
                    intdis=/dev/mmcblk1
                    intdis_prefix="p"
                    ;;
                "nvme")
                    intdis=/dev/nvme0
                    intdis_prefix="n"
                    ;;
                "sda")
                    intdis=/dev/sda
                    intdis_prefix=""
                    ;;
                *)
                    echo "An unknown error occurred. This should not have happened."
                    read -p "Press Enter to return to menu..."
                    return 1
                    ;;
                esac
            }
            
            get_internal || continue

            # Get the currently booted kernel partition ID
            BOOTED_KERN_ID=$(get_booted_kernnum)
            
            echo "Detected internal disk: $intdis"
            echo "Currently booted kernel partition: $BOOTED_KERN_ID"
            
            # Identify the inactive kernel and rootfs partitions
            if [ "$BOOTED_KERN_ID" -eq 2 ]; then
                INACTIVE_KERN_ID=4
                INACTIVE_ROOT_ID=5
            else
                INACTIVE_KERN_ID=2
                INACTIVE_ROOT_ID=3
            fi

            echo "Inactive kernel partition to delete: $INACTIVE_KERN_ID"
            echo "Inactive rootfs partition to delete: $INACTIVE_ROOT_ID"

            # Create necessary directories
            mkdir -p /localroot /stateful
            
            # Mount and prepare chroot environment
            BOOTED_ROOT_ID=$(get_booted_rootnum)
            echo "Mounting rootfs partition ${intdis}${intdis_prefix}${BOOTED_ROOT_ID}..."
            mount "${intdis}${intdis_prefix}${BOOTED_ROOT_ID}" /localroot -o ro 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to mount root partition"
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            mount --bind /dev /localroot/dev 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to bind mount /dev"
                umount /localroot
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            # Modify the active kernel partition attributes
            echo "Modifying attributes for active Kernel $BOOTED_KERN_ID..."
            chroot /localroot cgpt add "$intdis" -i "$BOOTED_KERN_ID" -P 10 -T 5 -S 1 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to modify partition attributes for Kernel $BOOTED_KERN_ID."
                echo "Check hardware write protection status or run as root."
                umount /localroot/dev
                umount /localroot
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            # Delete inactive partitions using fdisk
            echo "Deleting inactive partitions (Kernel $INACTIVE_KERN_ID and RootFS $INACTIVE_ROOT_ID)..."
            # Note: fdisk partition numbers are different from GPT partition indices!
            # For fdisk, we need to use the fdisk partition numbers, not GPT indices.
            # Typically, on ChromeOS devices, GPT partitions 2-5 correspond to fdisk partitions 1-4
            # But this can vary. We'll convert GPT indices to fdisk numbers.
            FDISK_KERN_NUM=$((INACTIVE_KERN_ID - 1))
            FDISK_ROOT_NUM=$((INACTIVE_ROOT_ID - 1))
            
            echo -e "d\n${FDISK_KERN_NUM}\nd\n${FDISK_ROOT_NUM}\nw" | chroot /localroot fdisk "$intdis" >/dev/null 2>&1
            
            # Alternative: Use cgpt to mark partitions as empty/removed
            # This might be safer than fdisk manipulation
            echo "Marking inactive partitions as empty..."
            chroot /localroot cgpt add "$intdis" -i "$INACTIVE_KERN_ID" -t unused 2>/dev/null
            chroot /localroot cgpt add "$intdis" -i "$INACTIVE_ROOT_ID" -t unused 2>/dev/null
            
            # Cleanup
            umount /localroot/dev
            umount /localroot
            rmdir /localroot 2>/dev/null
            
            # Disable developer mode warning
            crossystem disable_dev_request=1 2>/dev/null
            
            # Try to mount stateful partition (p1)
            echo "Attempting to mount stateful partition..."
            if ! mount "${intdis}${intdis_prefix}1" /stateful 2>/dev/null; then
                mountlvm
                if [ $? -ne 0 ]; then
                    read -p "Press Enter to return to menu..."
                    continue
                fi
            fi
            
            # Clear stateful partition
            echo "Clearing stateful partition..."
            rm -rf /stateful/*
            umount /stateful
            rmdir /stateful 2>/dev/null
            
            echo "DAUB completed successfully!"
            echo "DO NOT POWERWASH IN CHROMEOS! YOUR DEVICE WILL BOOTLOOP!"
            echo "(bootloop is fixable by recovering)"
            read -p "Press Enter to return to menu..."
            ;;
        2)
            echo "Type 'exit' to go back to main menu"
            bash
            ;;
        3)
            reboot -f
            ;;
        *)
            echo "Invalid option, please try again."
            read -p "Press Enter to return to menu..."
            ;;
    esac
done
