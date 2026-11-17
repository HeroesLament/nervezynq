# Builds oxibit (github.com/HeroesLament/oxibit, checked out beside this repo
# at ../../oxibit by default) and installs it into the app's priv/.
#
#   oxibit port   the PL: guarded loading and access  (Nervezynq.Fabric, Nervezynq.PL)
#   oxibit mem    PS-side memory: DDR, SLCR, DevC, GPIO (Nervezynq.PortWire, SLCR, scripts)
#
# Driven by elixir_make from mix.exs, which means it runs inside the Nerves
# build environment and inherits $CROSSCOMPILE, the toolchain prefix, e.g.
# .../armv7-nerves-linux-gnueabihf. Its presence is what distinguishes a target
# build from a host build; nothing here needs to know which target.
#
# Cortex-A9 wants the armv7 triple, NOT plain `arm-`: armv7-unknown-linux-gnueabihf
# is ARMv7-A with hardware float and NEON, which is what a Zynq-7020 has.
# The `arm-unknown-linux-gnueabihf` triple targets ARMv6 and would silently give
# up NEON and a good deal of performance.
#
# Using the Nerves gcc as the LINKER (rather than letting rustc pick a linker)
# is the part that actually matters: it is what makes Rust's std link against
# Buildroot's glibc and sysroot instead of the host's.

PRIV_DIR   = $(MIX_APP_PATH)/priv
OXIBIT_DIR ?= $(abspath $(CURDIR)/../../oxibit)
BIN        = oxibit

# Binaries this app used to ship. Removed from priv/ on every build so a stale
# copy can never end up in the firmware.
RETIRED    = fabric_port devcfg_load

ifeq ($(CROSSCOMPILE),)
  CARGO_FLAGS =
  CARGO_OUT   = $(OXIBIT_DIR)/target/release/$(BIN)
else
  TRIPLE      = armv7-unknown-linux-gnueabihf
  CARGO_FLAGS = --target $(TRIPLE)
  CARGO_OUT   = $(OXIBIT_DIR)/target/$(TRIPLE)/release/$(BIN)
  export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER = $(CROSSCOMPILE)-gcc
endif

SOURCES = $(OXIBIT_DIR)/Cargo.toml $(OXIBIT_DIR)/Cargo.lock \
          $(shell find $(OXIBIT_DIR)/crates -name '*.rs' -o -name Cargo.toml 2>/dev/null)

all: retired $(PRIV_DIR)/$(BIN)

$(PRIV_DIR)/$(BIN): $(SOURCES)
	@if [ ! -d "$(OXIBIT_DIR)/crates" ]; then \
		echo "oxibit not found at $(OXIBIT_DIR); clone it there or set OXIBIT_DIR" >&2; \
		exit 1; \
	fi
	@mkdir -p $(PRIV_DIR)
	cd $(OXIBIT_DIR) && cargo build --release -p oxibit $(CARGO_FLAGS)
	cp $(CARGO_OUT) $@

retired:
	@$(RM) $(addprefix $(PRIV_DIR)/,$(RETIRED))

clean:
	$(RM) $(PRIV_DIR)/$(BIN) $(addprefix $(PRIV_DIR)/,$(RETIRED))

.PHONY: all retired clean
