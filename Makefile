PREFIX ?= $(HOME)/.local
LABEL  := io.github.magacek.snag

build:
	swiftc -O -o build/snag Sources/*.swift

install:
	./install.sh

uninstall:
	./uninstall.sh

restart:
	launchctl kickstart -k gui/$(shell id -u)/$(LABEL)

log:
	tail -f $(HOME)/Library/Logs/snag.log

.PHONY: build install uninstall restart log
