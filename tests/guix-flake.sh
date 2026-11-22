# GNU Guix --- Functional package management for GNU
# Copyright © 2026 the Guix authors
#
# Test 'guix flake' and flake references on the command line.

set -e

# The evaluator runs in a container.
guile -c '(use-modules (guix pure-eval))
(exit (if (pure-eval-supported?) 0 77))'

root="$PWD/t-guix-flake-$$"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/dep" "$root/other" "$root/project"

# Checkouts, locks in effect and evaluations are cached below this.
XDG_CACHE_HOME="$root/cache"
export XDG_CACHE_HOME

commit ()
{
    git -C "$1" init -q
    git -C "$1" add -A
    git -C "$1" -c user.name=test -c user.email=test@example.org \
        commit -q -m "a commit"
}

fails ()
{
    if "$@"; then
        echo "unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

# A flake whose package 'word' holds the text given.
word_flake ()
{
    cat <<END
(flake
 (format 1)
 (outputs
  (lambda (in)
    (use-modules (guix) (guix build-system trivial) (gnu packages bootstrap))
    \`((packages
       (word . ,(package
                  (name "word") (version "0") (source #f)
                  (build-system trivial-build-system)
                  (arguments
                   (list #:guile %bootstrap-guile
                         #:builder
                         #~(call-with-output-file #\$output
                             (lambda (port) (display "$1" port)))))
                  (home-page #f) (synopsis #f) (description #f)
                  (license #f))))))))
END
}

word_flake "from dep" > "$root/dep/flake.scm"
commit "$root/dep"
word_flake "from other" > "$root/other/flake.scm"
commit "$root/other"

project="$root/project"
cat > "$project/flake.scm" <<END
(flake
 (format 1)
 (inputs (dep (git "$root/dep")))
 (options (suffix string "" "Text after the word"))
 (outputs
  (lambda (in)
    (use-modules (guix) (guix build-system trivial) (gnu packages bootstrap))
    (define (text name contents)
      (package
        (name name) (version "0") (source #f)
        (build-system trivial-build-system)
        (arguments
         (list #:guile %bootstrap-guile
               #:builder
               #~(call-with-output-file #\$output
                   (lambda (port) (display #\$contents port)))))
        (home-page #f) (synopsis #f) (description #f) (license #f)))
    (define word
      (input-output in 'dep 'packages 'word))
    (define sample
      (text "sample"
            #~(string-append
               (call-with-input-file #\$word (@ (ice-9 rdelim) read-line))
               #\$(option in 'suffix))))
    \`((packages (sample . ,sample))
      (checks (holds . ,sample))
      (templates (basic . "templates/basic"))))))
END
commit "$project"

#
# 'guix flake'.
#

# Nothing is evaluated without a lock, and the command says what to do.
fails guix build -d "$project#sample" 2> "$root/errors"
grep "guix flake lock" "$root/errors"

test "`guix flake lock -C "$project"`" = "$project/guix.lock"
cp "$project/guix.lock" "$root/lock"
guix flake lock -C "$project"
cmp "$project/guix.lock" "$root/lock"

guix flake metadata -C "$project" | grep "$root/dep"

guix flake show -C "$project" > "$root/shown"
grep '^packages sample .*-sample-0\.drv$' "$root/shown"
grep '^checks holds .*-sample-0\.drv$' "$root/shown"
grep '^templates basic -$' "$root/shown"

guix flake check -C "$project"
guix flake check -C "$project" --reproducible

# A flake that gives another answer each time is found out.
mkdir "$root/random"
cat > "$root/random/flake.scm" <<END
(flake
 (format 1)
 (outputs
  (lambda (in)
    (use-modules (guix) (guix build-system trivial) (gnu packages bootstrap))
    \`((packages
       (dice . ,(package
                  (name "dice")
                  (version (number->string
                            (random 1000000000 (random-state-from-platform))))
                  (source #f)
                  (build-system trivial-build-system)
                  (arguments (list #:guile %bootstrap-guile
                                   #:builder #~(mkdir #\$output)))
                  (home-page #f) (synopsis #f) (description #f)
                  (license #f))))))))
END
commit "$root/random"
guix flake check -C "$root/random"
fails guix flake check -C "$root/random" --reproducible 2> "$root/errors"
grep "packages dice is not the same in two evaluations" "$root/errors"

# Errors are reported the way commands report them.
fails guix flake lock -C "$root/nowhere" 2> "$root/errors"
grep "^guix flake: error: " "$root/errors"
fails grep -i backtrace "$root/errors"
fails guix flake frobnicate -C "$project"
fails guix flake update absent -C "$project"

mkdir "$root/new"
guix flake init -C "$root/new"
test -f "$root/new/flake.scm"
fails guix flake init -C "$root/new"

#
# A reference names an output.
#

drv="`guix build -d "$project#sample"`"
test "$drv" = "`sed -n 's/^packages sample //p' "$root/shown"`"
test "`cat "\`guix build "$project#sample"\`"`" = "from dep"

# From the flake's own directory.
(cd "$project"; test "`guix build -d .#sample`" = "$drv")

# An option of the flake.
test "`cat "\`guix build "$project#sample" --option=suffix=!\`"`" \
     = "from dep!"
fails guix build -d "$project#sample" --option=absent=1

# An override is for one run, and the lock stays as it is.
test "`cat "\`guix build "$project#sample" \
                --override-input=dep="$root/other"\`"`" = "from other"
cmp "$project/guix.lock" "$root/lock"
test "`guix build -d "$project#sample"`" = "$drv"

# An update moves the input.
word_flake "from dep, later" > "$root/dep/flake.scm"
commit "$root/dep"
test "`guix build -d "$project#sample"`" = "$drv"
guix flake update dep -C "$project"
fails cmp "$project/guix.lock" "$root/lock"
test "`cat "\`guix build "$project#sample"\`"`" = "from dep, later"

exit 0
