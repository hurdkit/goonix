# GNU Guix --- Functional package management for GNU
# Copyright © 2026 the Guix authors
#
# Test 'guix system ACTION --pure-eval': the action is carried out on an
# evaluation that ran in the container.

set -e

guile -c '(use-modules (guix pure-eval))
(exit (if (pure-eval-supported?) 0 77))'

project="$PWD/t-pure-eval-system-$$"
errors="$PWD/t-pure-eval-system-errors-$$"
trap 'rm -rf "$project" "$errors"' EXIT
mkdir "$project"
git -C "$project" init -q

make_system ()
{
    cat > "$project/$1" <<END
(use-modules (gnu))

(operating-system
  (host-name $2)
  (timezone "Europe/Paris")
  (locale "en_US.UTF-8")
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets (list "/dev/sdX"))))
  (file-systems (cons (file-system
                        (device (file-system-label "root"))
                        (mount-point "/")
                        (type "ext4"))
                      %base-file-systems)))
END
}

printf '"antelope"\n' > "$project/name"
make_system system.scm '(call-with-input-file "name" read)'
make_system impure.scm '(getenv "PURE_EVAL_HOST")'
git -C "$project" add name system.scm impure.scm

fails ()
{
    if "$@"; then
        echo "unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

cd "$project"

# Each action gives the derivation it gives without the option.
build="`guix system build system.scm -d`"
test -n "$build"
test "$build" = "`guix system build system.scm -d --pure-eval`"

image="`guix system image -t iso9660 system.scm -d`"
test "$image" = "`guix system image -t iso9660 system.scm -d --pure-eval`"
test "$image" != "$build"

# 'vm' is carried out too.  Its derivation is not the ordinary one: that one
# depends on whether this machine has /dev/kvm, which the container hides.
vm="`guix system vm system.scm -d --pure-eval`"
echo "$vm" | grep 'run-vm\.sh\.drv$'
test "$vm" = "`guix system vm system.scm -d --pure-eval`"

# An expression is evaluated in the container as well.
test "$build" = "`guix system build -d --pure-eval -e '(load "system.scm")'`"

# A dry run builds nothing and succeeds.
guix system build system.scm -n --pure-eval

# The environment is not there.
PURE_EVAL_HOST=antelope guix system build impure.scm -d
fails env PURE_EVAL_HOST=antelope guix system build impure.scm -d --pure-eval

# What acts on the machine is refused, with the reason.
fails guix system reconfigure system.scm --pure-eval 2> "$errors"
grep "acts on this machine" "$errors"

exit 0
