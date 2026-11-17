# Include board-specific packages (package/<name>/<name>.mk), if any.
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))
