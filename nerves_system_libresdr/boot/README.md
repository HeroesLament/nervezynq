# Boot artifacts

`BOOT.BIN` is currently the **vendor** LibreSDR first-stage image (FSBL +
u-boot) lifted from the stock SD card. It is not redistributable, which is the
main thing blocking this system from being published.

Replacing it is "Path B": generate `ps7_init.c` from the extracted register
tables, build the FSBL from regymm/embeddedsw, and pack with `mkbootimage`.
That also gets us a Nerves-aware u-boot -- the vendor onThat also gets us a Nerves-aware u-boot -- the vendor onThat also gets us a Nerves-aware u-boot -- the vendor onThat also gets us a Nerves-aware u-boot -- the vendor onThaclear; cat > post-createfs.sh <<'EOF'
#!/bin/sh

set -e

FWUP_CONFIG=$NERVES_DEFCONFIG_DIR/fwup.conf

# Run the common post-image processing for nerves
$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh $TARGET_DIR $FWUP_CONFIG

# --- Zynq boot artifacts -------------------------------------------------
#
# fwup.conf references BOOT.BIN, uEnv.txt and uImage as file-resources, but
# Buildroot produces none of them: BOOT.BIN is a prebuilt blob and u-boot on
# this board wants a uImage (legacy header) rather than the bare zImage that
# Buildroot emits. Generate them here so a plain `mix firmware` always works.
# Previously these were restored by hand after every system rebuild, which was
# a reliable source of "fwup: can't open path .../BOOT.BIN" surprises.

cp -f $NERVES_DEFCONFIG_DIR/boot/BOOT.BIN $BINARIES_DIR/BOOT.BIN
cp -f $NERVES_DEFCONFIG_DIR/boot/uEnv.txt $BINARIES_DIR/uEnv.txt

# Load/entry 0x8000 matches the vendor u-boot's expectations (verified against
# the stock uImage header).
$HOST_DIR/usr/bin/mkimage \
    -A arm -O linux -T kernel -C none \
    -a 0x8000 -e 0x8000 \
    -n "Nerves LibreSDR" \
    -d $BINARIES_DIR/zImage \
    $BINARIES_DIR/uImage > /dev/null

echo "post-createfs: installed BOOT.BIN, uEnv.txt and uImage"
