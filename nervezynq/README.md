# nervezynq

The Nerves application for the LibreSDR (Zynq-7020 + AD9363): AD9363 bring-up
over SPI, the `Nervezynq.Fabric` Rust port into the PL, bitstream loading,
capture and the SDR driver facade.

The only target is `libresdr`, the system in `../nerves_system_libresdr`
(built from source; see its `README.md`).

```sh
export MIX_TARGET=libresdr
mix deps.get
mix firmware                    # builds the system too, if its inputs changed
./upload.sh <board-ip>          # OTA to a running board; it reboots (~90 s)
```

A fresh card is written with fwup's `complete` task and a per-board serial:

```sh
sudo NERVES_SERIAL_NUMBER=lsdr-x fwup -a -i _build/libresdr_dev/nerves/images/nervezynq.fw \
    -t complete -d /dev/rdiskN
```

Read `AGENTS.md` before working on the code: board addresses, the bitstream
loading rules (a fabric access before a completed load hangs the CPU), the
watchdog, the Fabric port, and the AD9363 SPI framing.
