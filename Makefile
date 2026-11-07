PREFIX ?= $(HOME)/.local

.PHONY: build test install

build:
	swift build -c release

test:
	swift test

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 .build/release/kakao "$(DESTDIR)$(PREFIX)/bin/kakao"
	@printf 'Installed: %s/bin/kakao\n' "$(DESTDIR)$(PREFIX)"