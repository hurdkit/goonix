# goonix: what the fork adds to the build.  Makefile.am includes this file
# once its own lists of modules and tests are complete, so that the upstream
# file carries one hook instead of an entry per file.

MODULES +=					\
  guix/pure-eval.scm				\
  guix/package-overrides.scm			\
  guix/ca.scm					\
  guix/ca/derivation.scm				\
  guix/ca/policy.scm				\
  guix/ca/sharing.scm				\
  guix/ca/records.scm				\
  guix/ca/graft.scm				\
  guix/ca/build/graft.scm			\
  guix/ca/adopt.scm				\
  guix/ca/opaque.scm				\
  guix/ca/files.scm				\
  guix/download-cache.scm			\
  guix/ca/scan.scm				\
  guix/scripts/ca.scm				\
  guix/flakes.scm				\
  guix/flakes/syntax.scm			\
  guix/flakes/lock.scm				\
  guix/flakes/options.scm			\
  guix/flakes/checkout.scm			\
  guix/flakes/resolve.scm			\
  guix/flakes/evaluate.scm			\
  guix/flakes/evaluator.scm			\
  guix/flakes/support.scm			\
  guix/scripts/flake.scm			\
  guix/scripts/run.scm				\
  guix/secrets/gcrypt.scm			\
  guix/secrets/age.scm				\
  guix/secrets/declaration.scm			\
  guix/secrets/vault.scm			\
  guix/secrets/materialise.scm			\
  guix/scripts/secrets.scm			\
  gnu/services/goonix-secrets.scm		\
  gnu/home/services/goonix-secrets.scm

SCM_TESTS +=					\
  tests/ca.scm					\
  tests/ca-scan.scm				\
  tests/ca-build.scm				\
  tests/ca-compiler.scm				\
  tests/ca-grafts.scm				\
  tests/ca-graft-identity.scm			\
  tests/ca-adopt.scm				\
  tests/ca-files.scm				\
  tests/ca-full.scm				\
  tests/ca-opaque.scm				\
  tests/ca-policy.scm				\
  tests/ca-existing-item.scm			\
  tests/ca-fixed-output.scm			\
  tests/ca-references.scm			\
  tests/ca-rewrite.scm				\
  tests/ca-sharing.scm				\
  tests/download-cache.scm			\
  tests/flakes.scm				\
  tests/flake-eval.scm				\
  tests/flake-actions.scm			\
  tests/goonix-builders.scm			\
  tests/pure-eval.scm				\
  tests/store-path-check.scm			\
  tests/secrets-age.scm				\
  tests/secrets-age-vectors.scm			\
  tests/secrets-vault.scm			\
  tests/secrets-materialise.scm

SH_TESTS +=					\
  build-aux/check-goonix-hooks.sh		\
  tests/guix-ca-async.sh			\
  tests/guix-ca-two-store.sh			\
  tests/guix-ca-files.sh			\
  tests/guix-ca-second-machine.sh		\
  tests/guix-pure-eval.sh			\
  tests/guix-pure-eval-system.sh		\
  tests/guix-goonix-defaults.sh			\
  tests/guix-flake-shell.sh			\
  tests/guix-flake.sh				\
  tests/guix-secrets-age.sh			\
  tests/guix-secrets-ssh-age.sh		\
  tests/guix-secrets.sh

EXTRA_DIST +=					\
  build-aux/goonix-hooks.txt			\
  build-aux/goonix-upstream-base		\
  tests/ca-vectors.json				\
  tests/ca-async-fixture.scm			\
  tests/ca-two-store-fixture.scm			\
  tests/ca-files-fixture.scm			\
  tests/ca-files-client.scm			\
  tests/ca-files-corrupt-proxy.scm		\
  tests/ca-second-machine-fixture.scm		\
  tests/ca-untrusted-cache.scm			\
  tests/ca-cutoff.scm				\
  tests/fixtures/flake-shells.scm			\
  tests/fixtures/ca-self-token.gz			\
  tests/fixtures/ca-self-token.xz			\
  tests/fixtures/ca-self-token.bz2			\
  tests/fixtures/ca-self-token.zip			\
  tests/fixtures/ca-placeholder-boundary.gz		\
  tests/fixtures/age-identity.scrypt		\
  $(wildcard $(srcdir)/tests/fixtures/age/*)

if CAN_RUN_TESTS
if BUILD_DAEMON

# The checks of the finaliser that need a store of their own.  Each one is
# given an empty directory.
goonix_ca_store_checks =			\
  inverse-fragment				\
  opaque-utf					\
  fragment-boundary				\
  sibling-order					\
  staged					\
  leftover					\
  final-root					\
  siblings					\
  existing-item					\
  deep-scan					\
  streaming					\
  symlink-modes					\
  path-validation

EXTRA_DIST += doc/goonix-secrets.smd

# The vectors of the token and placeholder formats, the checks of the
# finaliser, then the unit tests of the build records against the test
# suite's own state directory and a 'guix' that runs from the build tree.
check-local:
	$(AM_V_at)$(abs_top_builddir)/nix/ca-test
if HAVE_LIBARCHIVE
	$(AM_V_at)$(abs_top_builddir)/nix/ca-scan-test $(abs_top_builddir)/goonix-ca-scan
endif HAVE_LIBARCHIVE
	$(AM_V_at)directory=`mktemp -d` || exit 1; \
	  $(abs_top_builddir)/nix/ca-test --shared-vectors \
	    $(abs_top_srcdir)/tests/ca-vectors.json "$$directory"; \
	  status=$$?; chmod -R u+w "$$directory"; rm -rf "$$directory"; \
	  test $$status -eq 0 || exit $$status
	$(AM_V_at)for check in $(goonix_ca_store_checks); do		\
	  directory=`mktemp -d` || exit 1;				\
	  $(abs_top_builddir)/nix/ca-test --$$check "$$directory";	\
	  status=$$?;							\
	  chmod -R u+w "$$directory"; rm -rf "$$directory";		\
	  if test $$status -ne 0; then					\
	    echo "nix/ca-test --$$check failed" >&2; exit 1;		\
	  fi;								\
	done
	$(AM_V_at)$(top_builddir)/test-env $(SHELL) -e -c \
	  'helper="$$GUIX_STATE_DIRECTORY/guix-helper"; \
	   printf "#!%s\nexec %s guix \"\$$@\"\n" "$$SHELL" \
	     "$(abs_top_builddir)/pre-inst-env" > "$$helper"; \
	   chmod +x "$$helper"; \
	   $(abs_top_builddir)/nix/records-test "$$GUIX_STATE_DIRECTORY" "$$helper"'

endif BUILD_DAEMON
endif CAN_RUN_TESTS
