#!/bin/sh

set -e

FWUP_CONFIG=$NERVES_DEFCONFIG_DIR/fwup.conf

# Run the common post-image processing for nerves
$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh $TARGET_DIR $FWUP_CONFIG

# --- Zynq boot artifacts -------------------------------------------------
#
# fwup.conf references BOOT.BIN, uEnv.txt and uImage as file-resources, but
# Buildroot produces none of them: BOOT.BIN is a prebuilt blob, and u-boot on
# this board wants a legacy-header uImage rather than the bare zImage that
# Buildroot emits. Generate them here so a plain `mix firmware` always works.
# These used to be restored by hand after every system rebuild, which was a
# reliable source of "fwup: can't open path .../BOOT.BIN".

cp -f "$NERVES_DEFCONFIG_DIR/boot/BOOT.BIN" "$BINARIES_DIR/BOOT.BIN"
cp -f "$NERVES_DEFCONFIG_DIR/boot/uEnv.txt"  "$BINARIES_DIR/uEnv.txt"
cp -f "$NERVES_DEFCONFIG_DIR/boot/u-boot.img" "$BINARIES_DIR/u-boot.img"

# Load/entry 0x8000 matches the vendor u-boot (verified against the stock
# uImage header).
"$HOST_DIR/usr/bin/mkimage" -A arm -O linux -T kernel -C none \
    -a 0x8000 -e 0x8000 -n "Nerves LibreSDR" \
    -d "$BINARIES_DIR/zImage" "$BINARIES_DIR/uImage" > /dev/null

# The stock Nerves build ships a prebuilt uboot-env.bin that does NOT track
# uboot/uboot.env -- edits to the boot script silently do nothing, and u-boot
# falls back to its compiled-in bootcmd. Regenerate it here so the A/B boot
# logic in uboot/uboot.env is actually what lands on the card.
# Size must match CONFIG_ENV_SIZE in u-boot (0x20000) and UBOOT_ENV_COUNT*512.
"$HOST_DIR/usr/bin/mkenvimage" -s 0x20000 -o "$BINARIES_DIR/uboot-env.bin" \
    "$NERVES_DEFCONFIG_DIR/uboot/uboot.env"

echo "post-createfs: installed BOOT.BIN, u-boot.img, uEnv.txt, uImage, uboot-env.bin"
