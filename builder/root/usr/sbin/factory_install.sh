#!/bin/bash
# daub script mostly by HarryTarryJarry

fail(){
	printf "$1\n"
	printf "exiting...\n"
	read -p "Press Enter to return to menu..."
	return 1
}

daub_main(){
	echo "Running daub.sh logic..."
	
	get_booted_kernnum() {
		# Assume intdis is set by get_internal
	    if $(expr $(cgpt show -n "$intdis" -i 2 -P) > $(cgpt show -n "$intdis" -i 4 -P)); then
	        echo -n 2
	    else
	        echo -n 4
	    fi
	}
	get_booted_rootnum() {
		expr $(get_booted_kernnum) + 1
	}
	opposite_num() {
	    if [ "$1" == "2" ]; then
	        echo -n 4
	    elif [ "$1" == "4" ]; then
	        echo -n 2
	    elif [ "$1" == "3" ]; then
	        echo -n 5
	    elif [ "$1" == "5" ]; then
	        echo -n 3
	    else
	        return 1
	    fi
	}

	get_internal_daub() {
		local ROOTDEV_LIST=$(cgpt find -t rootfs) 
		if [ -z "$ROOTDEV_LIST" ]; then
			fail "could not parse for rootdev devices. this should not have happened."
			return 1
		fi
		local device_type=$(echo "$ROOTDEV_LIST" | grep -oE 'blk0|blk1||nvme|sda' | head -n 1)
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
			fail "an unknown error occured. this should not have happened."
			return 1
			;;
		esac
	}
	wipelvm(){
	    chroot /localroot /sbin/vgchange -ay #active all volume groups
	    volgroup=$(chroot /localroot /sbin/vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
	    echo "found volume group: $volgroup"
	    if mount "/dev/$volgroup/unencrypted" /stateful; then
				rm -rf /stateful/*
				umount /stateful
				return 0
			else
				return 1
			fi
	}

	get_internal_daub || return
	echo "Detected internal disk: $intdis"
	
	mkdir -p /localroot /stateful
	
	mount "$intdis$intdis_prefix$(get_booted_rootnum)" /localroot -o ro || {
		fail "Failed to mount root partition."
		return 1
	}
	for rootdir in dev proc run sys; do
		mount --bindable "${rootdir}" /localroot/"${rootdir}" || {
			fail "Failed to bind mount ${rootdir}."
			return 1
		}
	done
	
	# Set kernel partition to priority 10, attempts 5, successful 1
	chroot /localroot cgpt add "$intdis" -i $(get_booted_kernnum) -P 10 -T 5 -S 1 || {
		fail "Failed to modify kernel partition attributes."
		return 1
	}
	
	# Delete the opposite kernel/root partitions (4 and 5)
	echo -e "d\n$(opposite_num $(get_booted_kernnum))\nd\n$(opposite_num $(get_booted_rootnum))\nw" | chroot /localroot /sbin/fdisk "$intdis" >/dev/null 2>&1
	
	# Set device request flag
	crossystem disable_dev_request=1
	
	# Wipe LVM or format stateful partition
	wipelvm || chroot /localroot /sbin/mkfs.ext4 -F "$intdis$intdis_prefix"p1
	
	# Cleanup mounts
	for rootdir in dev proc run sys; do
	  umount /localroot/"${rootdir}"
	done
	umount /localroot
	rm -rf /localroot /stateful
	
	echo "Done! You must reboot now."
	read -p "Press Enter to return to menu..."
}

# --- Functions used by Block Updates (Option 1) and LVM Mounting ---

# This version of get_internal is used by the *Block Updates* option (now option 1)
get_internal() {
	# get_largest_cros_blockdev does not work in BadApple.
	local ROOTDEV_LIST=$(cgpt find -t rootfs) # thanks stella
	if [ -z "$ROOTDEV_LIST" ]; then
		echo "Could not find root devices."
		read -p "Press Enter to return to menu..."
		return 1
	fi
	# Note: This version of get_internal uses 'mmc' instead of 'blk0|blk1' from the daub_main version
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

mountlvm(){
	vgchange -ay #active all volume groups
	volgroup=$(vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
	echo "found volume group:  $volgroup"
	mount "/dev/$volgroup/unencrypted" /stateful || {
		echo "couldnt mount p1 or lvm group.  Please recover"
		return 1
	}
}

# --- Main Menu Loop ---

while true; do
	clear
	echo ""
	echo "    ██████╗  █████╗ ██╗   ██╗██████╗ "
	echo "    ██╔══██╗██╔══██╗██║   ██║██╔══██╗"
	echo "    ██║  ██║███████║██║   ██║██████╔╝"
	echo "    ██║  ██║██╔══██║██║   ██║██╔══██╗"
	echo "    ██████╔╝██║  ██║╚██████╔╝██████╔╝"
	echo "    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝"
	echo "  depthcharge automatic update blocking"
	echo "          daub found by zeglol"
	echo "        script by HarryTarryJarry"
	echo ""

	echo "1) Block updates"
	echo "2) Run daub.sh"
	echo "3) Shell"
	echo "4) Reboot"
	read -p "Choose option: " choice

	case $choice in
		1)
			# Original Option 1: Block updates
			get_internal || continue
			
			echo "Detected internal disk: $intdis"
			
			# Create necessary directories
			mkdir -p /localroot /stateful
			
			# Mount and prepare chroot environment (mounts partition 3)
			mount "${intdis}${intdis_prefix}3" /localroot -o ro 2>/dev/null
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
			
			# Modify partition attributes (sets partition 2 to P=10, T=5, S=1)
			chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 2>/dev/null
			if [ $? -ne 0 ]; then
				echo "Failed to modify partition attributes"
				umount /localroot/dev
				umount /localroot
				read -p "Press Enter to return to menu..."
				continue
			fi
			
			# Use fdisk to delete partitions (deletes partitions 4 and 5)
			echo -e "d\n4\nd\n5\nw" | chroot /localroot fdisk "$intdis" >/dev/null 2>&1
			
			# Cleanup chroot mounts
			umount /localroot/dev
			umount /localroot
			rmdir /localroot
			
			crossystem disable_dev_request=1 2>/dev/null
			
			# Try to mount stateful partition
			if ! mount "${intdis}${intdis_prefix}1" /stateful 2>/dev/null; then
				mountlvm
				if [ $? -ne 0 ]; then
					read -p "Press Enter to return to menu..."
					continue
				fi
			fi
			
			# Clear stateful partition (Powerwash)
			rm -rf /stateful/*
			umount /stateful
			rmdir /stateful 2>/dev/null
			
			echo "DO NOT POWERWASH IN CHROMEOS! YOUR DEVICE WILL BOOTLOOP! (bootloop is fixable by recovering)"
			echo "DAUB completed successfully!"
			read -p "Press Enter to return to menu..."
			;;
		2)
			# New Option 2: Run daub.sh
			daub_main
			;;
		3)
			# Original Option 2 -> New Option 3: Shell
			echo "Type 'exit' to go back to main menu"
			/bin/bash 2>/dev/null
			;;
		4)
			# Original Option 3 -> New Option 4: Reboot
			reboot -f
			;;
		*)
			echo "Invalid option, please try again..."
			read -p "Press Enter to return to menu..."
			;;
	esac
done
