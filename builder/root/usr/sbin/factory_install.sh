#!/bin/bash
# script mostly by HarryTarryJarry

while true; do
    clear
    echo ""
    echo "    ██████╗  █████╗ ██╗   ██╗██████╗ "
    echo "    ██╔══██╗██╔══██╗██║   ██║██╔══██╗"
    echo "    ██║  ██║███████║██║   ██║██████╔╝"
    echo "    ██║  ██║██╔══██║██║   ██║██╔══██╗"
    echo "    ██████╔╝██║  ██║╚██████╔╝██████╔╝"
    echo "    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝"
    echo "  depthcharge automatic update blocking"
    echo "             found by zeglol"
    echo "     script mostly by HarryTarryJarry"
    echo ""

    echo "1) Block updates"
    echo "2) Bash shell"
    echo "3) Reboot"
    read -p "Choose option: " choice

    case $choice in
        1)
            echo "Starting Daub..."
            
            # get_internal take from https://github.com/applefritter-inc/BadApple-icarus
            get_internal() {
                # get_largest_cros_blockdev does not work in BadApple.
                local ROOTDEV_LIST=$(cgpt find -t rootfs) # thanks stella
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
                    echo "an unknown error occured. this should not have happened."
                    read -p "Press Enter to return to menu..."
                    return 1
                    ;;
                esac
            }
            
            get_internal || continue

			get_booted_kernnum() {
                # This assumes intdis is set, which get_internal() handles later.
                if $(expr $(cgpt show -n "$intdis" -i 2 -P) > $(cgpt show -n "$intdis" -i 4 -P)); then
                    echo -n 2
                else
                    echo -n 4
                fi
            }

            get_booted_rootnum() {
	            expr $(get_booted_kernnum) + 1
            }
			
            echo "Detected internal disk: $intdis"
            
            # Create necessary directories
            mkdir -p /localroot /stateful
            
            # Mount and prepare chroot environment
            mount "${intdis}${intdis_prefix}$(get_booted_rootnum)" /localroot -o ro 2>/dev/null
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
            
            # Modify partition attributes
            chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "Failed to modify partition attributes"
                umount /localroot/dev
                umount /localroot
                read -p "Press Enter to return to menu..."
                continue
            fi
            
            # Use fdisk to delete partitions
            echo -e "d\n4\nd\n5\nw" | chroot /localroot fdisk "$intdis" >/dev/null 2>&1
            
            # Cleanup
            umount /localroot/dev
            umount /localroot
            rmdir /localroot
            
            crossystem disable_dev_request=1 2>/dev/null

            if mount "${intdis}${intdis_prefix}1" /stateful 2>/dev/null; then
                umount /stateful
                chroot /localroot mkfs.ext4 -F "${intdis}${intdis_prefix}1"
            else
                mountlvm
                if [ $? -ne 0 ]; then
                    read -p "Press Enter to return to menu..."
                    continue
                fi
                rm -rf /stateful/*
                umount /stateful
            fi

            echo "daub completed successfully!"
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

mountlvm(){
     vgchange -ay #active all volume groups
     volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
     echo "found volume group:  $volgroup"
     mount "/dev/$volgroup/unencrypted" /stateful || {
         echo "couldnt mount p1 or lvm group.  Please recover"
         return 1
     }
}
