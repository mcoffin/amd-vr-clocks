SCRIPT_NAME := amd-vr-clocks.sh

.DEFAULT_GOAL := $(SCRIPT_NAME)

PREFIX ?= /usr/local
DESTDIR ?= /

install: $(SCRIPT_NAME)
	install -Dm 0755 -t $(DESTDIR)/./$(PREFIX)/bin $(SCRIPT_NAME)

.PHONY: install
