#!/bin/sh

set -e

FWUP_CONFIG=$NERVES_DEFCONFIG_DIR/fwup.conf

# Run the common post-image processing for nerves
$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh $TARGET_DIR $FWUP_CONFIG

# --- Zynq boot artifacts -------------------------------------------------
#
# fwup.conf references BOOT.BIN, u-boot.img and uImage as
# file-resources. U-Boot and its SPL are built from source by Buildroot
# (BR2_TARGET_UBOOT, docs/boot-chain.md), which installs spl/boot.bin as
# boot.bin and u-boot.img into $BINARIES_DIR; the BootROM wants the SPL named
# BOOT.BIN on the FAT partition. u-boot on this board also wants a
# legacy-header uImage rather than the bare zImage Buildroot emits.

cp -f "$BINARIES_DIR/boot.bin" "$BINARIES_DIR/BOOT.BIN"

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

# --- Board device tree ---------------------------------------------------
#
# Buildroot compiles BR2_LINUX_KERNEL_CUSTOM_DTS_DIR only when the linux
# package itself rebuilds. Its stamp files do not track dts/, so an edited
# zynq-libresdr.dts changes the Nerves artifact checksum, triggers a system
# build, and still ships the OLD dtb (seen 2026-09-28 with reset-on-timeout).
# Compile it here instead, on every system build, with the same preprocessor
# and dtc flags as the kernel's own dtb rule, overwriting the kernel's copy.

compile_board_dtb() {
    local dts="$NERVES_DEFCONFIG_DIR/dts/xilinx/zynq-libresdr.dts"
    local out="$BINARIES_DIR/zynq-libresdr.dtb"
    local linux_dir
    local dtc

    linux_dir=$(ls -d "$BUILD_DIR"/linux-custom "$BUILD_DIR"/linux-[0-9]* 2>/dev/null | head -n 1)
    if [ -z "$linux_dir" ]; then
        echo "post-createfs: no kernel source tree under $BUILD_DIR" >&2
        exit 1
    fi

    # Prefer the kernel's own dtc so the output matches `make dtbs`.
    dtc="$linux_dir/scripts/dtc/dtc"
    if [ ! -x "$dtc" ]; then
        dtc="$HOST_DIR/usr/bin/dtc"
    fi

    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "$linux_dir/arch/arm/boot/dts/xilinx" \
        -I "$linux_dir/arch/arm/boot/dts" \
        -I "$linux_dir/scripts/dtc/include-prefixes" \
        -I "$linux_dir/include" \
        "$dts" > "$BUILD_DIR/zynq-libresdr.dts.pp"

    "$dtc" -q -I dts -O dtb -b 0 -o "$out" "$BUILD_DIR/zynq-libresdr.dts.pp"
    echo "post-createfs: compiled $(basename "$out") from dts/ ($(wc -c < "$out") bytes)"
}

compile_board_dtb

echo "post-createfs: installed BOOT.BIN, u-boot.img, uImage, uboot-env.bin"
