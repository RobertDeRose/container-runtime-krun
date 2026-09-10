SHELL := /bin/bash
SWIFT ?= swift
CONFIG ?= release
BUILD_DIR := .build/arm64-apple-macosx/$(CONFIG)
INSTALL_ROOT ?= $(shell python3 scripts/install_root.py 2>/dev/null)
PLUGIN_DIR := $(INSTALL_ROOT)/libexec/container-plugins/container-runtime-krun

.PHONY: build release test check sign install uninstall doctor

build:
	$(SWIFT) build

release:
	$(SWIFT) build -c release --arch arm64
	$(MAKE) sign CONFIG=release

sign:
	codesign --force --sign - "$(BUILD_DIR)/container-runtime-krun"
	codesign --force --sign - --entitlements signing/hypervisor.entitlements "$(BUILD_DIR)/container-krun-vmm-helper"

install: release
	@test -n "$(INSTALL_ROOT)" || { echo "Unable to derive INSTALL_ROOT; pass INSTALL_ROOT=/path/to/container prefix" >&2; exit 1; }
	mkdir -p "$(PLUGIN_DIR)/bin"
	cp plugin/container-runtime-krun/config.toml "$(PLUGIN_DIR)/config.toml"
	cp "$(BUILD_DIR)/container-runtime-krun" "$(PLUGIN_DIR)/bin/container-runtime-krun"
	cp "$(BUILD_DIR)/container-krun-vmm-helper" "$(PLUGIN_DIR)/bin/container-krun-vmm-helper"
	@echo "Installed $(PLUGIN_DIR)"
	@echo "Restart Apple Container with: container system stop && container system start"

uninstall:
	@test -n "$(INSTALL_ROOT)" || { echo "Unable to derive INSTALL_ROOT; pass INSTALL_ROOT=/path/to/container prefix" >&2; exit 1; }
	rm -rf "$(PLUGIN_DIR)"

# Core tests require Apple Container dependencies and therefore run on macOS.
test:
	$(SWIFT) test

check:
	$(SWIFT) package dump-package >/dev/null
	@for file in $$(find Sources Tests -name '*.swift' -print); do $(SWIFT)c -frontend -parse "$$file" || exit 1; done
	python3 scripts/check_contract.py
	git diff --check

doctor:
	@command -v container >/dev/null || { echo "container not found" >&2; exit 1; }
	@command -v swift >/dev/null || { echo "swift not found" >&2; exit 1; }
	@test -r /opt/homebrew/lib/libkrun.dylib -o -r /usr/local/lib/libkrun.dylib || { echo "libkrun.dylib not found" >&2; exit 1; }
	@echo "container=$$(command -v container)"
	@echo "install-root=$(INSTALL_ROOT)"
	@brew list --versions libkrun virglrenderer 2>/dev/null || true
