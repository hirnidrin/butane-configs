.PHONY: all clean help ucore-pulpo

# Default target builds all server configs
all: ucore-pulpo

help:
	@echo "Available targets:"
	@echo "  all         - Build all server configs (default)"
	@echo "  ucore-pulpo - Build ucore-pulpo server config"
	@echo "  clean       - Remove all generated files"
	@echo "  help        - Show this help message"
	@echo ""
	@echo "Before building, ensure each server directory has a .env file"
	@echo "Copy from .env.example and fill with real values"

# ucore-pulpo server build
ucore-pulpo: ucore-pulpo/pulpo-autorebase.ign
ucore-pulpo/: ucore-pulpo

ucore-pulpo/pulpo-autorebase.ign: ucore-pulpo/pulpo-autorebase.butane
	@echo "Building Ignition config: $@"
	butane --strict < $< > $@

ucore-pulpo/pulpo-autorebase.butane: ucore-pulpo/pulpo-autorebase.butane.template ucore-pulpo/.env
	@echo "Generating Butane config from template: $@"
	@test -f ucore-pulpo/.env || (echo "Error: ucore-pulpo/.env not found. Copy from ucore-pulpo/.env.example and fill with real values" && exit 1)
	@set -a; . ucore-pulpo/.env; set +a; envsubst < $< > $@

# Clean all generated files
clean:
	@echo "Cleaning generated files..."
	rm -f ucore-pulpo/*.butane ucore-pulpo/*.ign
	@echo "Done"
