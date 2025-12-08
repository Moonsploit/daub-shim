#!/bin/bash
# daub script mostly written by HarryTarryJarry
# Fix applied: Dynamic detection of the active root partition using 'rootdev -s'
# instead of hardcoding partition 3.

# Helper function to mount LVM stateful partition
mountlvm(){
    vgchange -ay # active all volume groups
    volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    echo "found volume group:  $volgroup"
    mount "/dev/$volgroup/unencrypted" /stateful || {
        echo "couldn't mount p1 or lvm group. Please recover"
        return 1
    }
}

while true; do
    clear
    echo ""
    echo "    ██████╗  █████╗ ██╗   ██╗██████╗ "
    echo "    ██╔══██╗██╔══██╗██║   ██║██╔══██╗"
    echo "    ██║  ██║███████║██║   ██║██████╔╝"
    echo "    ██║  ██║██╔══██║██║   ██║██╔══██╗"
    echo "    ██████╔╝██║  ██║╚██████╔╝██████╔╝"
    echo "    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝"
    echo "  depthcharge automatic update blocking"
    echo "             found by zeglol"
    echo "        script by HarryTarryJarry"
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
            
            # --- START FIX: Dynamically determine the active root partition ---
            ROOT_DEV=$(rootdev -s)
            if [ -z "$ROOT_DEV" ]; then
                echo "Error: Could not determine active root device using 'rootdev -s'."
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

# The mountlvm function remains unchanged, as it handles the stateful partition mount logic.
mountlvm(){
    vgchange -ay #active all volume groups
    volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    echo "found volume group:  $volgroup"
    mount "/dev/$volgroup/unencrypted" /stateful || {
        echo "couldnt mount p1 or lvm group.  Please recover"
        return 1
    }
}
