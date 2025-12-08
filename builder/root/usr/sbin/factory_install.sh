#!/bin/sh
# written mostly by HarryJarry1
# get_stateful take from https://github.com/applefritter-inc/BadApple-icarus
fail(){
	printf "$1\n"
	printf "exiting...\n"
	exit
}
main(){
echo   
get_internal
mkdir -p /localroot /stateful
mount "$intdis$intdis_prefix$(get_booted_rootnum)" /localroot -o ro
for rootdir in dev proc run sys; do
	mount --bindable "${rootdir}" /localroot/"${rootdir}"
done
chroot /localroot cgpt add "$intdis" -i $(get_booted_kernnum) -P 10 -T 5 -S 1
    (
        echo "d"
        echo "$(opposite_num $(get_booted_kernnum))"
        echo "d"
        echo "$(opposite_num $(get_booted_rootnum))"
        echo "w" 
    ) | chroot /localroot /sbin/fdisk "$intdis"
crossystem disable_dev_request=1
wipelvm || chroot /localroot /sbin/mkfs.ext4 -F "$intdis$indis_prefix"p1
for rootdir in dev proc run sys; do
  umount /localroot/"${rootdir}"
done
umount /localroot
rm -rf /localroot /stateful
echo "Done!  Run reboot -f to reboot."
}
wipelvm(){
    chroot /localroot /sbin/vgchange -ay #active all volume groups
    volgroup=$(chroot /localroot /sbin/vgscan | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    echo "found volume group: $volgroup"
    if mount "/dev/$volgroup/unencrypted" /stateful; then
			rm -rf /stateful/*
			umount /stateful
		fi
}
get_internal() {
	# get_largest_cros_blockdev does not work in BadApple.
	local ROOTDEV_LIST=$(cgpt find -t rootfs) # thanks stella
	if [ -z "$ROOTDEV_LIST" ]; then
		fail "could not parse for rootdev devices. this should not have happened."
	fi
	local device_type=$(echo "$ROOTDEV_LIST" | grep -oE 'blk0|blk1||nvme|sda' | head -n 1)
	case $device_type in
	"blk0")
		intdis=/dev/mmcblk0
  		intdis_prefix="p"
		break
		;;
	"blk1")
		intdis=/dev/mmcblk1
			intdis_prefix="p"
		break
		;;
	"nvme")
		intdis=/dev/nvme0
  		intdis_prefix="n"
		break
		;;
	"sda")
		intdis=/dev/sda
  		intdis_prefix=""
		break
		;;
	*)
		fail "an unknown error occured. this should not have happened."
		;;
	esac
}
get_booted_kernnum() {
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
read -p "are you sure you want to run daub?  (y/n) " -n 1 -r
echo   
if [[ $REPLY =~ ^[Yy]$ ]]; then
    main
fi
