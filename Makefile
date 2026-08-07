SERVERS := $(notdir $(wildcard servers/*))

# Servers are addressable as `make nuc26`, `make servers/nuc26` and
# `make servers/nuc26/` - the last one is what shell tab-completion gives you.
SERVER_TARGETS := $(SERVERS) $(addprefix servers/,$(SERVERS)) $(addsuffix /,$(addprefix servers/,$(SERVERS)))

.PHONY: all clean help $(SERVER_TARGETS)

# Bare `make` prints help - building a server is always an explicit choice.
.DEFAULT_GOAL := help

help:
	@echo "Available targets:"
	@echo "  help     - Show this help message (default)"
	@echo "  all      - Build every server config"
	@echo "  clean    - Remove all generated files"
	@echo ""
	@echo "Servers (found in servers/):"
	@$(foreach s,$(SERVERS),echo "  $(s)";)
	@echo ""
	@echo "Each server needs a .env file - copy its .env.example and fill in real values."

all: $(SERVERS)

# Builds are milliseconds, so always rebuild rather than track the snippet
# list as a prerequisite.
$(SERVER_TARGETS):
	@./build.sh $@

clean:
	@echo "Cleaning generated files..."
	@rm -rf servers/*/.build
	@rm -f servers/*/*.butane servers/*/*.ign
	@echo "Done"
