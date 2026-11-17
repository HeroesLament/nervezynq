#!/bin/sh

set -e

# Create the fwup ops script to handling MicroSD/eMMC operations at runtime
# NOTE: revert.fw is the previous, more limited version of this. ops.fw is
#       backwards compatible.
mkdir -p $TARGET_DIR/usr/share/fwup
$HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR

# U-Boot loads the kernel (uImage.<slot>) and DTB (zynq-libresdr.<slot>.dtb)
# from the FAT boot partition, not from the rootfs. The kernel install still
# puts zImage and zynq-libresdr.dtb in /boot; the DTB there would also be
# stale, since the authoritative one is compiled later by post-createfs.sh.
# Remove both so the rootfs carries no boot files.
rm -f $TARGET_DIR/boot/zImage $TARGET_DIR/boot/*.dtb
