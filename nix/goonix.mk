# goonix: optional unprivileged compressed-output scanner.
if BUILD_DAEMON
if HAVE_LIBARCHIVE
libexec_PROGRAMS = goonix-ca-scan
goonix_ca_scan_SOURCES = %D%/goonix-ca-scan.cc
goonix_ca_scan_CPPFLAGS = $(guix_daemon_CPPFLAGS) $(LIBARCHIVE_CFLAGS)
goonix_ca_scan_LDADD = libutil.a -lz $(LIBARCHIVE_LIBS)
noinst_PROGRAMS += nix/ca-scan-test
nix_ca_scan_test_SOURCES = %D%/ca-scan-test.cc
nix_ca_scan_test_CPPFLAGS = $(guix_daemon_CPPFLAGS)
nix_ca_scan_test_LDADD = libutil.a
endif HAVE_LIBARCHIVE

# goonix: manual root-only runner test; exits 77 for an unprivileged caller.
noinst_PROGRAMS += nix/ca-scan-root-test
nix_ca_scan_root_test_SOURCES = %D%/libstore/deep-scan-root-test.cc
nix_ca_scan_root_test_CPPFLAGS = $(guix_daemon_CPPFLAGS)
nix_ca_scan_root_test_LDADD = libstore.a libutil.a -lz $(SQLITE3_LIBS) $(LIBGCRYPT_LIBS)
if HAVE_LIBBZ2
nix_ca_scan_root_test_LDADD += -lbz2
endif HAVE_LIBBZ2
noinst_PROGRAMS += nix/ca-scan-identity
nix_ca_scan_identity_SOURCES = %D%/ca-scan-identity.cc
nix_ca_scan_identity_CPPFLAGS = $(guix_daemon_CPPFLAGS)
nix_ca_scan_identity_LDADD = libutil.a

# goonix: native stubs remain executable in the helper's empty environment.
noinst_PROGRAMS += nix/ca-scan-crash nix/ca-scan-stall
nix_ca_scan_crash_SOURCES = %D%/ca-scan-crash.cc
nix_ca_scan_crash_CPPFLAGS = $(guix_daemon_CPPFLAGS)
nix_ca_scan_stall_SOURCES = %D%/ca-scan-stall.cc
nix_ca_scan_stall_CPPFLAGS = $(guix_daemon_CPPFLAGS)
endif BUILD_DAEMON
