#!/bin/bash
# daub script mostly written by HarryTarryJarry

mountlvm(){
    vgchange -ay # active all volume groups
    volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    echo "found volume group:  $volgroup"
    mount "/dev/$volgroup/unencrypted" /stateful || {
        echo "couldn't mount p1 or lvm group. Please recover"
        return 1
    }
}

# Helper function to find the active root device using cgpt priority
find_active_root_cgpt() {
    local intdis=$1  # e.g., /dev/sda
    local intdis_prefix=$2 # e.g., p or n

    # Get the boot priority for partition 2 (ROOT-A) and partition 4 (ROOT-B)
    local p2_priority=$(cgpt show -i 2 -q -P "$intdis")
    local p4_priority=$(cgpt show -i 4 -q -P "$intdis")

    # If priority for 2 is higher or equal to 4 (and 2 exists), use partition 2
    if [ -n "$p2_priority" ] && [ "$p2_priority" -ge "$p4_priority" ]; then
        echo "${intdis}${intdis_prefix}2"
    # Otherwise, if priority for 4 is higher (and 4 exists), use partition 4
    elif [ -n "$p4_priority" ] && [ "$p4_priority" -ge "$p2_priority" ]; then
        echo "${intdis}${intdis_prefix}4"
    else
        # Fallback if cgpt gives non-standard results or priorities are zero/unreadable
        echo "${intdis}${intdis_prefix}2"
    fi
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
    echo "            found by zeglol"
    echo "          script by HarryTarryJarry"
    echo ""

    echo "1) Block updates"
    echo "2) Shell"
    echo "3) Reboot"
    read -p "Choose option: " choice

    case $choice in
        1)
            # get_internal take from https://github.com/applefritter-inc/BadApple-icarus
            get_internal() {
                local ROOTDEV_LIST=$(cgpt find -t rootfs) # thanks stella
                if [ -z "$ROOTDEV_LIST" ]; then
                    echo "Could not find root devices."
                    read -p "Press Enter to return to menu..."
                    return 1
                fi
                local device_type=$(echo "$ROOTDEV_LIST" | grep -oE 'mmc|nvme|sda' | head -n 1)
                case $device_type in
                "mmc")
                    intdis=/dev/mmcblk0
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
                    echo "an unknown error occured. this should not have happened."
                    read -p "Press Enter to return to menu..."
                    return 1
                    ;;
                esac
            }
            
            get_internal || continue
            
            # --- START FIX: Determine the active root partition using cgpt priority ---
            ROOT_DEV=$(find_active_root_cgpt "$intdis" "$intdis_prefix")

            if [ -z "$ROOT_DEV" ]; then
                echo "Error: Could not determine active root device using cgpt."
                read -p "Press Enter to return to menu..."
                continue
            fi

            echo "Detected internal disk: $intdis"
            echo "Detected active root partition: $ROOT_DEV"
            
            # Create necessary directories
            mkdir -p /localroot /stateful
            
            # Mount the ACTIVE root partition (e.g., /dev/sda4 or /dev/nvme0n2)
            mount "$ROOT_DEV" /localroot -o ro 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to mount active root partition ($ROOT_DEV)."
                rmdir /localroot 2>/dev/null
                rmdir /stateful 2>/dev/null
                read -p "Press Enter to return to menu..."
                continue
            fi
            # --- END FIX ---
            
            mount --bind /dev /localroot/dev 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to bind mount /dev"
                umount /localroot 2>/dev/null
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            # Modify partition attributes (Partition 2 is one of the kernel/root pairs)
            chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to modify partition attributes for partition 2."
                umount /localroot/dev 2>/dev/null
                umount /localroot 2>/dev/null
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            # Use fdisk to delete partitions (typically ROOT-B/KERN-B partitions 4 and 5)
            echo -e "d\n4\nd\n5\nw" | chroot /localroot fdisk "$intdis" >/dev/null 2>&1
            
            # Cleanup
            umount /localroot/dev 2>/dev/null
            umount /localroot 2>/dev/null
            rmdir /localroot 2>/dev/null
            
            # Disable dev request via crossystem
            crossystem disable_dev_request=1 2>/dev/null
            
            # Try to mount stateful partition (Partition 1)
            # The structure for partition 1 is: "${intdis}${intdis_prefix}1"
            if ! mount "${intdis}${intdis_prefix}1" /stateful 2>/dev/null; then
                # If direct mount fails, attempt LVM mount
                mountlvm
                if [ $? -ne 0 ]; then
                    read -p "Press Enter to return to menu..."
                    continue
                fi
            fi
            
            # Clear stateful partition
            rm -rf /stateful/*
            umount /stateful 2>/dev/null
            echo "DO NOT POWERWASH IN CHROMEOS! YOUR DEVICE WILL BOOTLOOP! (bootloop is fixable by recovering)"
            echo "DAUB completed successfully!"
            read -p "Press Enter to return to menu..."
            ;;
        2)
            echo "Type 'exit' to go back to main menu"
            /bin/bash 2>/dev/null
            ;;
        3)
            reboot -f
            ;;
        *)
            echo "Invalid option, please try again..."
            read -p "Press Enter to return to menu..."
            ;;
    esac
done
