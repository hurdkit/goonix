# GNU Guix --- Functional package management for GNU
#
# This file is part of GNU Guix.
#
# GNU Guix is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

if BUILD_HASKELL_DAEMON

bin_PROGRAMS =
noinst_LIBRARIES =
BUILT_SOURCES += daemon/src/Goonix/Config.hs
CLEANFILES += daemon/src/Goonix/Config.hs guix-daemon guix-sandbox \
  guix-daemon.tmp guix-sandbox.tmp goonix-ca-scan goonix-ca-scan.tmp

# goonix: the out-of-process CA decoder must ship in the Haskell package too.
# The C++ target graph (nix/local.mk, nix/goonix.mk) is not included in this
# mode, so build the helper here from the same sources, against the same
# libutil objects and libarchive, and install it into libexec.  The daemon's
# default helper path is the make-expanded libexecdir (Goonix.Config), so the
# installed package finds it with no GOONIX_DEEP_SCAN_HELPER override.
if HAVE_LIBARCHIVE
BUILT_SOURCES += goonix-ca-scan
goonix-ca-scan: $(top_srcdir)/nix/goonix-ca-scan.cc \
    $(top_srcdir)/nix/libutil/util.cc $(top_srcdir)/nix/libutil/affinity.cc \
    nix/config.h
	$(AM_V_CXX)$(CXX) $(DEFS) $(DEFAULT_INCLUDES) \
	  -I$(top_srcdir)/nix/libutil $(LIBARCHIVE_CFLAGS) \
	  $(CPPFLAGS) -std=c++20 -O2 -Wall $(CXXFLAGS) $(LDFLAGS) \
	  -o $@.tmp $(top_srcdir)/nix/goonix-ca-scan.cc \
	  $(top_srcdir)/nix/libutil/util.cc $(top_srcdir)/nix/libutil/affinity.cc \
	  -lz $(LIBARCHIVE_LIBS); \
	  mv $@.tmp $@
endif HAVE_LIBARCHIVE

# The sandbox helper is built in the source tree with the daemon, so Guix's
# existing GUIX_SANDBOX override and tests can select this exact binary.
guix-sandbox: $(top_srcdir)/daemon/sandbox/guix-sandbox.cc $(top_srcdir)/daemon/cbits/helpers.c
	$(AM_V_GEN)$(CC) $(CPPFLAGS) $(CFLAGS) -O2 -c \
	  $(top_srcdir)/daemon/cbits/helpers.c -o $@-helpers.o && \
	$(CXX) $(CPPFLAGS) $(AM_CXXFLAGS) $(CXXFLAGS) -std=c++17 \
	  -O2 -Wall -Wextra -Wpedantic $(LDFLAGS) $(LDLIBS) -o $@.tmp \
	  $(top_srcdir)/daemon/sandbox/guix-sandbox.cc $@-helpers.o && \
	mv $@.tmp $@
# Keep the direct build independent of Cabal's package database and of Hackage.
DAEMON_GHC_FLAGS = -O2 -Wall -Wcompat -Widentities -Wredundant-constraints \
  -threaded -rtsopts -with-rtsopts=-N \
  -XGHC2024 -XStrictData -package process -package directory \
  -i$(top_srcdir)/daemon/src \
  -i$(top_builddir)/daemon/src $(LIBGCRYPT_CPPFLAGS) \
  $(LIBGCRYPT_LDFLAGS) $(LIBGCRYPT_LIBS) $(SQLITE3_CFLAGS) $(SQLITE3_LIBS) \
  -lz -lbz2

# Keep source prerequisites explicit: GHC writes objects under ghc-build, not
# at the paths emitted by ghc -M. A source edit must always dirty this target.
DAEMON_SOURCES = $(shell find $(top_srcdir)/daemon/app $(top_srcdir)/daemon/src \
  $(top_srcdir)/daemon/cbits \( -name '*.hs' -o -name '*.c' -o -name '*.h' \))

guix-daemon: guix-sandbox $(DAEMON_SOURCES) daemon/src/Goonix/Config.hs
	$(AM_V_GEN)$(GHC) --make $(DAEMON_GHC_FLAGS) \
	  -outputdir daemon/ghc-build -o $@.tmp \
	  $(top_srcdir)/daemon/cbits/sockets.c \
  $(top_srcdir)/daemon/cbits/files.c \
  $(top_srcdir)/daemon/cbits/helpers.c \
  $(top_srcdir)/daemon/cbits/logs.c \
	  $(top_srcdir)/daemon/app/Main.hs; mv $@.tmp $@

install-exec-local: guix-daemon guix-sandbox
	$(MKDIR_P) "$(DESTDIR)$(bindir)"
	$(INSTALL_PROGRAM) guix-daemon "$(DESTDIR)$(bindir)/guix-daemon"
	$(INSTALL_PROGRAM) guix-sandbox "$(DESTDIR)$(bindir)/guix-sandbox"
if HAVE_LIBARCHIVE
	$(MKDIR_P) "$(DESTDIR)$(libexecdir)"
	$(INSTALL_PROGRAM) goonix-ca-scan "$(DESTDIR)$(libexecdir)/goonix-ca-scan"
endif HAVE_LIBARCHIVE

uninstall-local: uninstall-haskell-daemon
uninstall-haskell-daemon:
	rm -f "$(DESTDIR)$(bindir)/guix-daemon" "$(DESTDIR)$(bindir)/guix-sandbox"
if HAVE_LIBARCHIVE
	rm -f "$(DESTDIR)$(libexecdir)/goonix-ca-scan"
endif HAVE_LIBARCHIVE

daemon/src/Goonix/Config.hs: Makefile guix/store/schema.sql
	$(AM_V_GEN)$(MKDIR_P) daemon/src/Goonix; \
	$(GUILE) --no-auto-compile $(top_srcdir)/daemon/make-config.scm \
	  "$@" "$(storedir)" "$(localstatedir)/guix" \
	  "$(localstatedir)/log/guix" "$(sysconfdir)/guix" "$(bindir)" \
	  "$(libexecdir)" "$(localedir)" "$(guix_system)" "$(GUIX_SUBSTITUTE_URLS)" \
	  "$(top_srcdir)/guix/store/schema.sql"

else !BUILD_HASKELL_DAEMON
# The Haskell build owns a different target graph.  Force the existing C++
# target to relink when configure switches back, even if a stub is newer.
.PHONY: guix-daemon
endif !BUILD_HASKELL_DAEMON

EXTRA_DIST += \
  daemon/cabal.project daemon/guix-daemon.cabal daemon/local.mk \
  daemon/make-config.scm daemon/app/Main.hs \
  daemon/src/Goonix/Store/Wire.hs \
  daemon/src/Goonix/Store/Base32.hs daemon/src/Goonix/Store/Hash.hs \
  daemon/src/Goonix/Store/Database.hs daemon/src/Goonix/Store/ReadOnly.hs \
  daemon/src/Goonix/Store/Settings.hs daemon/src/Goonix/Store/Server.hs \
  daemon/src/Goonix/Store/Config.hs daemon/src/Goonix/Store/Socket.hs \
  daemon/src/Goonix/Store/GuixProgram.hs \
  daemon/src/Goonix/Store/Substitute.hs daemon/src/Goonix/Store/Archive.hs daemon/src/Goonix/Build/Engine.hs daemon/src/Goonix/Build/Offload.hs daemon/src/Goonix/Build/Scheduler.hs daemon/src/Goonix/Build/Shared.hs daemon/src/Goonix/Build/Wait.hs daemon/cbits/sockets.c daemon/cbits/files.c \
  daemon/src/Goonix/Store/Path.hs daemon/src/Goonix/Store/Derivation.hs \
  daemon/src/Goonix/Store/Nar.hs daemon/src/Goonix/Store/References.hs \
  daemon/src/Goonix/Store/Ca.hs \
  daemon/src/Goonix/Store/DeepScan.hs daemon/src/Goonix/Store/RecordSignature.hs \
  daemon/test/record-signature/Main.hs \
  daemon/src/Goonix/Build/CaDecision.hs daemon/src/Goonix/Build/Runtime.hs \
  daemon/src/Goonix/Build/Graph.hs daemon/src/Goonix/Build/Scheduler.hs \
  daemon/test/scheduler/Main.hs daemon/test/ca-decision/Main.hs \
  daemon/test/ca-vectors/Main.hs \
  daemon/test/ca-leftover/Main.hs daemon/test/ca-leftover.sh \
  daemon/test/rewrite-mode/Main.hs daemon/test/rewrite-mode.sh \
  nix/libstore/rewrite-mode-probe.cc \
  daemon/test/dedup-mode/Main.hs daemon/test/dedup-mode.sh \
  nix/libstore/dedup-probe.cc \
  daemon/test/delete-mode/Main.hs daemon/test/delete-mode.sh \
  nix/libstore/delete-probe.cc \
  daemon/test/register-mode/Main.hs daemon/test/register-mode.sh \
  nix/libstore/register-probe.cc \
  daemon/test/reserved-mode/Main.hs daemon/test/reserved-mode.sh \
  nix/libstore/reserved-probe.cc \
  daemon/test/inverse-mode/Main.hs daemon/test/inverse-mode.sh \
  nix/libstore/inverse-probe.cc \
  daemon/test/order-mode/Main.hs daemon/test/order-mode.sh \
  nix/libstore/order-probe.cc \
  daemon/test/same-mode/Main.hs daemon/test/same-mode.sh \
  nix/libstore/same-probe.cc \
  daemon/test/inverse-sibling-boundary.hs daemon/test/inverse-sibling-boundary.sh \
  daemon/test/symlink-concurrent.hs daemon/test/symlink-concurrent.sh \
  daemon/test/rewrite-boundary.hs daemon/test/rewrite-boundary.sh \
  daemon/test/rewrite-speed/Main.hs daemon/test/rewrite-speed.sh \
  nix/libstore/rewrite-speed-probe.cc \
  daemon/test/rewrite-boundary-mode/Main.hs daemon/test/rewrite-boundary-mode.sh \
  nix/libstore/rewrite-boundary-probe.cc \
  daemon/test/gcroot-mode/Main.hs daemon/test/gcroot-mode.sh \
  nix/libstore/gcroot-probe.cc \
  daemon/test/deep-scan-timeout.hs daemon/test/deep-scan-timeout.sh \
  daemon/proxy/Main.hs \
  daemon/test/wire-proxy/Main.hs daemon/test/wire-proxy/run.sh \
  daemon/test/wire-proxy/inventory.scm daemon/test/check-build-flags.scm \
  daemon/test/formats/Main.hs daemon/test/properties/Main.hs \
  daemon/test/readonly/RawClient.hs daemon/test/readonly/Activate.hs \
  daemon/test/differential/prepare-write-fixture.sh \
  daemon/test/differential/write.sh \
  daemon/test/differential/write-probe.scm \
  daemon/test/differential/archive-probe.scm \
  daemon/test/differential/build.sh \
  daemon/test/differential/prepare-readonly-fixture.sh \
  daemon/test/differential/read-only.sh daemon/test/differential/transports.sh \
  daemon/test/differential/guix-readonly.sh \
  daemon/test/differential/socket-startup.sh \
  daemon/test/differential/stale-socket.c daemon/test/differential/socket-connect.c \
  daemon/test/differential/socket-query.c \
  daemon/test/differential/builtin-ci.sh daemon/test/differential/builtin-ci.scm \
  daemon/test/differential/regressions.sh \
  daemon/test/differential/cabal-modules.sh \
  daemon/test/differential/dedup-overflow.sh daemon/test/differential/dedup-overflow-test.c \
  daemon/test/differential/dedup-linkcount-test.c \
  daemon/test/differential/delete-hardlink.sh daemon/test/differential/delete-hardlink.hs \
  daemon/test/differential/sqlite-contention.sh daemon/test/differential/sqlite-contention.hs \
  daemon/test/differential/socket-idle.sh daemon/test/differential/socket-idle.hs \
  daemon/test/differential/child-wait.sh daemon/test/differential/child-wait.hs \
  daemon/test/differential/wait-stack.sh daemon/test/differential/wait-stack.hs \
  daemon/test/differential/offload-idle.sh daemon/test/differential/offload-idle.hs \
  daemon/test/differential/offload-eof.sh daemon/test/differential/offload-eof.hs \
  daemon/test/differential/offload-flood.sh daemon/test/differential/offload-flood.hs \
  daemon/test/differential/offload-flood-helper.sh \
  daemon/test/differential/sandbox-plan-stable.hs \
  daemon/test/differential/sandbox-plan-stable.sh \
  daemon/test/differential/export-memory.sh daemon/test/differential/export-memory.scm \
  daemon/test/differential/nar-memory.sh daemon/test/differential/nar-memory.scm \
  daemon/test/differential/substitute-log-flood.sh daemon/test/differential/substitute-log-flood.scm \
  daemon/test/differential/substitute-log-flood-helper.sh \
  daemon/test/differential/substitute-silent.sh daemon/test/differential/substitute-silent.scm \
  daemon/test/differential/substitute-silent-helper.sh \
  daemon/test/differential/stress-gate.sh daemon/test/differential/stress-gate-part.sh \
  daemon/test/differential/stress-noisy-helper.sh \
  daemon/test/differential/root-ci-part.sh \
  daemon/test/differential/pidns-guard.sh daemon/test/differential/pidns-isolation.sh \
  daemon/test/differential/stress-build.scm daemon/test/differential/stress-substitute.scm \
  daemon/test/differential/stress-gc.scm daemon/test/differential/stress-roots.scm \
  daemon/test/differential/stress-watchdog.scm daemon/test/differential/stress-verify.scm \
  daemon/test/differential/build-probe.scm daemon/test/differential/build-probe-nons.sh \
  daemon/test/differential/build-probe-diag.sh \
  daemon/test/differential/nar-import-probe.scm daemon/test/differential/nar-import-probe.sh \
  daemon/test/differential/root-ci.sh daemon/test/differential/root-ci-setup.sh \
  daemon/test/differential/root-ci-client.scm daemon/test/differential/root-ci-http.sh \
  daemon/test/differential/root-ci-killuser.scm daemon/test/differential/root-ci-substitute.sh \
  daemon/test/differential/ca-counted-gate.sh \
  daemon/test/differential/ca-counted-gate-part.sh \
  daemon/test/differential/ca-deep-scan-installed.sh \
  daemon/test/differential/ca-deep-scan-installed-part.sh \
  daemon/test/differential/root-ci-part.sh \
  daemon/test/differential/pidns-guard.sh daemon/test/differential/pidns-isolation.sh \
  daemon/sandbox/README.md daemon/sandbox/guix-sandbox.cc \
  daemon/sandbox/Makefile daemon/test/lib.sh daemon/test/seed-restore.scm \
  daemon/test/sandbox-helper-cleanup.sh daemon/test/sandbox-helper-cleanup.scm \
  daemon/test/sandbox-probe/README.md \
  daemon/test/sandbox-probe/UPSTREAM-REUSE.md \
  daemon/test/sandbox-probe/ThreadedUnshareProbe.hs \
  daemon/test/sandbox-probe/child-inspect.c \
  daemon/test/sandbox-probe/gate.sh daemon/test/sandbox-probe/spawn.c \
  daemon/test/vectors/README.md \
  daemon/test/vectors/Generate.hs daemon/test/vectors/dump-nar.cc \
  daemon/test/vectors/hash-nar.cc daemon/test/vectors/inspect-item.cc \
  daemon/test/vectors/hash-derivations.cc \
  daemon/test/vectors/generate.sh daemon/test/compare-trs.sh \
  daemon/test/scan-real-store-fixture.sh daemon/test/scan-real-store-fixture.scm \
  daemon/test/scan-real-store.sh daemon/test/scan-real-store.scm \
  daemon/test/RESULTS.md \
  daemon/test/transcripts/README.md \
  daemon/test/transcripts/inventory.wire.log \
  daemon/test/transcripts/inventory-client.log

.PHONY: check-daemon-differential check-haskell-daemon-build check-cxx-daemon-build check-daemon-build-flags
check-daemon-build-flags:
	$(GUILE) --no-auto-compile $(top_srcdir)/daemon/test/check-build-flags.scm \
	  $(top_srcdir)/daemon/guix-daemon.cabal $(top_srcdir)/daemon/local.mk

check-cxx-daemon-build: check-daemon-build-flags
	./config.status --recheck
	./configure --disable-haskell-daemon
	$(MAKE) -j1 guix-daemon

check-haskell-daemon-build: check-daemon-build-flags
	./config.status --recheck
	./configure --with-ghc="$(GHC)"
	$(MAKE) -j1 guix-daemon

check-daemon-differential:
	$(AM_V_GEN)$(GHC) --make -XGHC2024 -XStrictData \
	  -i$(top_srcdir)/daemon/src -i$(top_srcdir)/daemon/test/differential \
	  $(top_srcdir)/daemon/test/differential/Main.hs \
	  -o daemon/check-differential && daemon/check-differential
