# Provenance of vendored reference material

The `ref/` directory holds third-party upstream repositories that were cloned
locally for reference while building this project. They are **not** committed
to this repository (`ref/` is in `.gitignore`) because they carry their own
git history and licenses. Clone them yourself if you want them:

| Local path | Upstream | Purpose |
|------------|----------|---------|
| `ref/libresdr` | https://github.com/hz12opensource/libresdr | The LibreSDR hardware's stock design and board documentation. |
| `ref/GenZ` | https://github.com/regymm/GenZ | Zynq bring-up / reference material used while working out the boot and PL-load path. |

Other reference material consulted but not vendored:

- **Analog Devices `no-OS`** (`drivers/rf-transceiver/ad9361/`) — the
  authoritative source for AD9363 SPI framing and register semantics. The SPI
  command grammar and register addresses in `nervezynq/lib/nervezynq/ad9363/`
  are transcribed from ADI's driver, cited in-file at the point of use.

If you're reproducing the build, treat the URLs above as the source of truth;
nothing in this repository depends on the local `ref/` copies at build time.
