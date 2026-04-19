.PHONY: all clean help ucore-pulpo ucore-hci ucore-quader brucore-quader wucore-quader

# Default target builds all server configs
all: ucore-pulpo ucore-hci ucore-quader brucore-quader

help:
	@echo "Available targets:"
	@echo "  all            - Build all server configs (default)"
	@echo "  ucore-pulpo    - Build ucore-pulpo server config"
	@echo "  ucore-hci      - Build ucore-hci server config"
	@echo "  ucore-quader   - Build ucore-quader server config"
	@echo "  brucore-quader - Build brucore-quader server config"
	@echo "  wucore-quader  - Build wucore-quader server config"
	@echo "  clean          - Remove all generated files"
	@echo "  help           - Show this help message"
	@echo ""
	@echo "Before building, ensure each server directory has a .env file"
	@echo "Copy from .env.example and fill with real values"

# ucore-pulpo server build
#
ucore-pulpo: ucore-pulpo/autorebase.ign
ucore-pulpo/: ucore-pulpo

ucore-pulpo/autorebase.ign: ucore-pulpo/autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@

ucore-pulpo/autorebase.butane: ucore-pulpo/autorebase.butane.template ucore-pulpo/.env
	@echo "Generating Butane config from template: $@"
	@test -f ucore-pulpo/.env || (echo "Error: ucore-pulpo/.env not found. Copy from ucore-pulpo/.env.example and fill with real values" && exit 1)
	@set -a; . ucore-pulpo/.env; set +a; envsubst < $< > $@

# ucore-hci server build
#
ucore-hci: ucore-hci/autorebase.ign
ucore-hci/: ucore-hci
#
ucore-hci/autorebase.ign: ucore-hci/autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@
#
ucore-hci/autorebase.butane: ucore-hci/autorebase.butane.template ucore-hci/.env
	@echo "Generating Butane config from template: $@"
	@test -f ucore-hci/.env || (echo "Error: ucore-hci/.env not found. Copy from ucore-hci/.env.example and fill with real values" && exit 1)
	@set -a; . ucore-hci/.env; set +a; envsubst < $< > $@

# ucore-quader server build
#
ucore-quader: ucore-quader/autorebase.ign
ucore-quader/: ucore-quader
#
ucore-quader/autorebase.ign: ucore-quader/autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@
#
ucore-quader/autorebase.butane: ucore-quader/autorebase.butane.template ucore-quader/.env
	@echo "Generating Butane config from template: $@"
	@test -f ucore-quader/.env || (echo "Error: ucore-quader/.env not found. Copy from ucore-quader/.env.example and fill with real values" && exit 1)
	@set -a; . ucore-quader/.env; set +a; envsubst < $< > $@

# brucore-quader server build
#
brucore-quader: brucore-quader/autorebase.ign
brucore-quader/: brucore-quader
#
brucore-quader/autorebase.ign: brucore-quader/autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@
#
brucore-quader/autorebase.butane: brucore-quader/autorebase.butane.template brucore-quader/.env
	@echo "Generating Butane config from template: $@"
	@test -f brucore-quader/.env || (echo "Error: brucore-quader/.env not found. Copy from brucore-quader/.env.example and fill with real values" && exit 1)
	@set -a; . brucore-quader/.env; set +a; envsubst < $< > $@

# wucore-quader server build
#
wucore-quader: wucore-quader/autorebase.ign
wucore-quader/: wucore-quader
#
wucore-quader/autorebase.ign: wucore-quader/autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@
#
wucore-quader/autorebase.butane: wucore-quader/autorebase.butane.template wucore-quader/.env
	@echo "Generating Butane config from template: $@"
	@test -f wucore-quader/.env || (echo "Error: wucore-quader/.env not found. Copy from wucore-quader/.env.example and fill with real values" && exit 1)
	@set -a; . wucore-quader/.env; set +a; envsubst < $< > $@

# Clean all generated files
clean:
	@echo "Cleaning generated files..."
	rm -f ucore-pulpo/*.butane ucore-pulpo/*.ign
	rm -f ucore-hci/*.butane ucore-hci/*.ign
	rm -f ucore-quader/*.butane ucore-quader/*.ign
	rm -f brucore-quader/*.butane brucore-quader/*.ign
	rm -f wucore-quader/*.butane wucore-quader/*.ign
	@echo "Done"
