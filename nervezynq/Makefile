# Builds the Rust fabric port and installs it into the app's priv/.
#
# Driven by elixir_make from mix.exs, which means it runs inside the Nerves
# build environment and inherits $CROSSCOMPILE — the toolchain prefix, e.g.
# .../arm-unknown-linux-gnueabihf. Its presence is what distinguishes a target
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

PRIV_DIR  = $(MIX_APP_PATH)/priv
CRATE_DIR = native/fabric
BIN       = fabric_port
BIN2      = devcfg_load

ifeq ($(CROSSCOMPILE),)
  CARGO_FLAGS =
  CARGO_OUT   = $(CRATE_DIR)/target/release/$(BIN)
  CARGO_OUT2  = $(CRATE_DIR)/target/release/$(BIN2)
else
  TRIPLE      = armv7-unknown-linux-gnueabihf
  CARGO_FLAGS = --target $(TRIPLE)
  CARGO_OUT   = $(CRATE_DIR)/target/$(TRIPLE)/release/$(BIN)
  CARGO_OUT2  = $(CRATE_DIR)/target/$(TRIPLE)/release/$(BIN2)
  export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER = $(CROSSCOMPILE)-gcc
endif

SOURCES = $(CRATE_DIR)/Cargo.toml $(CRATE_DIR)/src/lib.rs $(CRATE_DIR)/src/main.rs \
          $(CRATE_DIR)/src/devcfg.rs

all: $(PRIV_DIR)/$(BIN) $(PRIV_DIR)/$(BIN2)

$(PRIV_DIR)/$(BIN): $(SOURCES)
	@mkdir -p $(PRIV_DIR)
	cd $(CRATE_DIR) && cargo build --release $(CARGO_FLAGS)
	cp $(CARGO_OUT) $@

$(PRIV_DIR)/$(BIN2): $(SOURCES)
	@mkdir -p $(PRIV_DIR)
	cd $(CRATE_DIR) && cargo build --release $(CARGO_FLAGS)
	cp $(CARGO_OUT2) $@

clean:
	cd $(CRATE_DIR) && cargo clean
	$(RM) $(PRIV_DIR)/$(BIN) $(PRIV_DIR)/$(BIN2)

.PHONY: all clean
