PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

install:
	install -Dm755 claude-sessions $(DESTDIR)$(BINDIR)/claude-sessions

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/claude-sessions

test:
	./test.sh

.PHONY: install uninstall test
