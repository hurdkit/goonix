# GNU Guix --- Functional package management for GNU
# Copyright © 2026 the Guix authors
#
# Test '--pure-eval': the evaluation runs in a container that shows the
# tracked files of the project and nothing else of the host.

set -e

# The container needs unprivileged user namespaces.
guile -c '(use-modules (guix pure-eval))
(exit (if (pure-eval-supported?) 0 77))'

project="$PWD/t-pure-eval-project-$$"
outside="$PWD/t-pure-eval-outside-$$"
trap 'rm -rf "$project" "$outside"' EXIT
mkdir -p "$project/sub" "$project/modules/my" "$outside"
printf 'outside\n' > "$outside/secret"
git -C "$project" init -q

cat > "$project/environment.scm" <<'END'
(use-modules (guix tests))
(dummy-package "pure-eval-environment"
  (version (or (getenv "PURE_EVAL_PROBE")
               (error "environment variable is missing"))))
END

cat > "$project/outside.scm" <<END
(use-modules (guix tests) (ice-9 rdelim))
(dummy-package "pure-eval-outside"
  (version (call-with-input-file "$outside/secret" read-line)))
END

cat > "$project/home.scm" <<'END'
(use-modules (guix tests))
(dummy-package "pure-eval-home"
  (version (if (file-exists? (string-append (getenv "HOME") "/probe"))
               "0"
               (error "the home directory is not the user's"))))
END

cat > "$project/tracked.scm" <<'END'
(use-modules (guix tests))
(dummy-package "pure-eval-tracked" (version "0"))
END
cat > "$project/untracked.scm" <<'END'
(use-modules (guix tests))
(dummy-package "pure-eval-untracked" (version "0"))
END
cat > "$project/tracked-project.scm" <<'END'
(load "tracked.scm")
END
cat > "$project/untracked-project.scm" <<'END'
(load "untracked.scm")
END
cat > "$project/sub/parent.scm" <<'END'
(load "../tracked.scm")
END
cat > "$project/noisy.scm" <<'END'
(use-modules (guix tests))
(display "NOISE\n")
(dummy-package "pure-eval-noisy" (version "0"))
END
cat > "$project/source.scm" <<'END'
(use-modules (guix tests) (guix packages) (guix download))
(dummy-package "pure-eval-source"
  (version "0")
  (source (origin
            (method url-fetch)
            (uri "http://localhost/pure-eval-source.tar.gz")
            (sha256 (base32
                     "0000000000000000000000000000000000000000000000000000")))))
END
cat > "$project/manifest.scm" <<'END'
(use-modules (guix profiles))
(packages->manifest (list (load "tracked.scm")))
END
cat > "$project/modules/my/tracked.scm" <<'END'
(define-module (my tracked)
  #:use-module (guix tests)
  #:export (my-tracked))
(define my-tracked (dummy-package "pure-eval-my-tracked" (version "0")))
END
cat > "$project/modules/my/untracked.scm" <<'END'
(define-module (my untracked)
  #:use-module (guix tests)
  #:export (my-untracked))
(define my-untracked (dummy-package "pure-eval-my-untracked" (version "0")))
END
git -C "$project" add environment.scm outside.scm home.scm tracked.scm \
    tracked-project.scm untracked-project.scm sub/parent.scm noisy.scm \
    source.scm manifest.scm modules/my/tracked.scm

fails ()
{
    if "$@"; then
        echo "unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

# The same command with and without the option gives the same derivation.
same ()
{
    impure="`guix build -d "$@"`"
    pure="`guix build -d --pure-eval "$@"`"
    test -n "$impure"
    test "$impure" = "$pure"
}

#
# What the container hides.  Each control shows that the probe works in an
# ordinary evaluation.
#

home="$outside/home"
mkdir "$home"
touch "$home/probe"

PURE_EVAL_PROBE=impure guix build -d -f "$project/environment.scm"
fails env PURE_EVAL_PROBE=impure \
      guix build -d -f "$project/environment.scm" --pure-eval
fails env PURE_EVAL_PROBE=impure \
      guix build --pure-eval -d -f "$project/environment.scm"

guix build -d -f "$project/outside.scm"
fails guix build --pure-eval -d -f "$project/outside.scm"

HOME="$home" guix build -d -f "$project/home.scm"
fails env HOME="$home" guix build --pure-eval -d -f "$project/home.scm"

guix build -d -f "$project/untracked-project.scm"
fails guix build --pure-eval -d -f "$project/untracked-project.scm"

(cd "$project"
 guix build -d -L modules -e '(@ (my untracked) my-untracked)'
 fails guix build --pure-eval -d -L modules \
       -e '(@ (my untracked) my-untracked)')

# A file that is in no checkout cannot be shown at all.
plain="`mktemp -d`"
cp "$project/tracked.scm" "$plain/plain.scm"
guix build -d -f "$plain/plain.scm"
fails guix build --pure-eval -d -f "$plain/plain.scm"
rm -r "$plain"

#
# What it must not change.
#

same -f "$project/tracked-project.scm"

# File names mean what they mean outside: relative to the current
# directory, and across directories of the project.
(cd "$project/sub"; same -f parent.scm)
(cd "$project"; same -f sub/parent.scm)

# The options of the command apply inside.
same -f "$project/tracked.scm" --system=i686-linux
other="`guix build -d --pure-eval -f "$project/tracked.scm" --system=i686-linux`"
test -n "$other"
test "$other" != "`guix build -d --pure-eval -f "$project/tracked.scm"`"
same -S -f "$project/source.scm"
guix build -d --pure-eval -S -f "$project/source.scm" \
    | grep 'pure-eval-source\.tar\.gz\.drv$'
same -m "$project/manifest.scm"
(cd "$project"; same -L modules -e '(@ (my tracked) my-tracked)')

# An expression sees the checkout of the current directory.
(cd "$project"; same -e '(load "tracked.scm")')
(cd "$project"; fails guix build -d --pure-eval -e '(load "untracked.scm")')

# What the project prints is not part of the result.
quiet="`guix build -d --pure-eval -f "$project/noisy.scm" 2> /dev/null`"
test -n "$quiet"
test "$quiet" = "`guix build -d -f "$project/noisy.scm" | grep -v NOISE`"

#
# 'guix shell': the profile is the one an ordinary evaluation makes.
#

shell_paths ()
{
    guix shell --bootstrap "$@" --search-paths
}

cat > "$project/shell.scm" <<'END'
(use-modules (guix) (guix build-system trivial)
             (gnu packages bootstrap))

(define (tool name propagated)
  (package
    (name name) (version "0") (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:guile %bootstrap-guile
           #:builder
           #~(begin
               (mkdir #$output)
               (mkdir (string-append #$output "/bin"))
               (mkdir (string-append #$output "/tools"))
               (call-with-output-file
                   (string-append #$output "/bin/" #$name)
                 (const #t)))))
    (propagated-inputs propagated)
    (native-search-paths
     (list (search-path-specification
            (variable "PURE_EVAL_TOOLS")
            (files '("tools")))))
    (home-page #f) (synopsis #f) (description #f) (license #f)))

(tool "pure-eval-tool" (list (tool "pure-eval-propagated" '())))
END
git -C "$project" add shell.scm

impure="`shell_paths -f "$project/shell.scm"`"
test -n "$impure"
test "$impure" = "`shell_paths --pure-eval -f "$project/shell.scm"`"
shell_paths --pure-eval -f "$project/shell.scm" | grep PURE_EVAL_TOOLS

# The propagated input is in the profile.
profile="`shell_paths --pure-eval -f "$project/shell.scm" \
          | sed -n 's|^export PATH="\([^":]*\)/bin.*|\1|p'`"
test -e "$profile/bin/pure-eval-tool"
test -e "$profile/bin/pure-eval-propagated"

# An impure file is refused there as well.
fails env PURE_EVAL_PROBE=impure \
      guix shell --bootstrap --pure-eval -f "$project/environment.scm" \
      --search-paths

exit 0
