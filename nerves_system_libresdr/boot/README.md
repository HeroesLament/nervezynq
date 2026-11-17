# Boot artifacts

`BOOT.BIN` (U-Boot SPL with `ps7_init`) and `u-boot.img` are built from source
by Buildroot from U-Boot 2025.01 plus `../uboot/patches/`. They are not kept
here. The full description (boot flow, patch series, provenance, verification,
deployment, recovery) is in `../docs/boot-chain.md`.

| File | What it is |
|---|---|
| `BOOT.BIN.2026-07-28`, `u-boot.img.2026-07-28` | The binaries that booted these boards from 2026-07-28 until the from-source build replaced them. Reference for verification and last-resort recovery. Not used by the build. |
| `BOOT.BIN.vendor-backup` | The stock LibreSDR FSBL + u-boot image from the vendor SD card. Reference only; not redistributable. |

No `.bit` file belongs here. A bitstream on the boot partition is programmed by
U-Boot before Linux and hung the boot once (`docs/journal/HANDOFF.md`, "SOLVED:
the board did not boot because U-Boot was programming the PL at boot").
