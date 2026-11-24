# GNU Guix --- Functional package management for GNU
# Copyright © 2026 goonix contributors
#
# This file is part of GNU Guix.
#
# GNU Guix is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or (at
# your option) any later version.
#
# GNU Guix is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

#
# goonix: 'guix shell' with a flake.  The flake's code runs in a container,
# never in the 'guix shell' process, and a flake.scm that is merely found
# needs the same authorization as a guix.scm.
#

set -e

guix shell --version

# The evaluation needs user namespaces.
guile -c '(use-modules (gnu build linux-container))
(exit (if (and (user-namespace-supported?)
               (unprivileged-user-namespace-supported?)
               (setgroups-supported?))
          0 77))'

configdir="t-guix-flake-shell-config-$$"
project="t-guix-flake-shell-project-$$"
trap 'rm -rf "$configdir" "$project"' EXIT
mkdir -p "$configdir/guix" "$project"
XDG_CONFIG_HOME="$(realpath "$configdir")"
export XDG_CONFIG_HOME
project="$(realpath "$project")"
marker="$project/evaluated-on-the-host"

# The flake tries to leave a file on the host when it is evaluated.  In the
# container that directory does not exist, so nothing may appear.
sed -e "s|@MARKER@|$marker|" > "$project/flake.scm" <<'EOF2'
(flake (format 1)
 (outputs (lambda (in)
  (use-modules (guix tests) (guix build-system trivial)
               (gnu packages bootstrap))
  (false-if-exception
   (call-with-output-file "@MARKER@"
     (lambda (port) (display "evaluated" port))))
  (define (tool name)
    (dummy-package name
      (build-system trivial-build-system)
      (arguments
       (quasiquote
        (#:guile ,%bootstrap-guile
         #:builder
         (begin
           (mkdir %output)
           (mkdir (string-append %output "/bin"))
           (call-with-output-file (string-append %output "/bin/" ,name)
             (lambda (port) (display ,name port)))
           #t))))))
  `((packages (tool . ,(tool "flake-shell-tool")))
    (shells (default . ,(shell (packages (list (tool "flake-shell-default")))
                               (environment
                                '(("FLAKE_SHELL" . "default")))))
            (other . ,(shell (packages (list (tool "flake-shell-other")))
                             (environment
                              '(("FLAKE_SHELL" . "other"))))))))))
EOF2
git -C "$project" init -q
git -C "$project" add flake.scm

show='echo "$FLAKE_SHELL"; ls "$GUIX_ENVIRONMENT/bin"'

# A reference names the shell; its variables and its packages are there.
test "$(guix shell --bootstrap "$project#other" -- "$SHELL" -c "$show")" \
     = "other
flake-shell-other"
test ! -e "$marker"

# A directory alone names its default shell.
test "$(guix shell --bootstrap "$project" -- "$SHELL" -c "$show")" \
     = "default
flake-shell-default"

# A package that is no shell is entered as a shell of itself.
test "$(guix shell --bootstrap "$project#tool" -- "$SHELL" -c "$show")" \
     = "
flake-shell-tool"

# A flake shell is a whole environment; it does not mix with packages.
if guix shell --bootstrap "$project#other" guile-bootstrap -- true
then false
fi

# Without arguments and without a command, nothing is loaded from a
# directory that was not authorized, as for 'guix.scm'.
cat > "$project/fake-shell.sh" <<EOF2
#!$SHELL
# This fake shell allows us to test interactive use.
echo "\$FLAKE_SHELL"
exec ls "\$GUIX_ENVIRONMENT/bin"
EOF2
chmod +x "$project/fake-shell.sh"

if (cd "$project"; SHELL="$project/fake-shell.sh" guix shell --bootstrap \
        2> "$project/stderr")
then false
fi
grep "not authorized" "$project/stderr"
test ! -e "$marker"

# Once the directory is authorized, the default shell is entered.
echo "$project" > "$configdir/guix/shell-authorized-directories"
test "$(cd "$project"; SHELL="$project/fake-shell.sh" guix shell --bootstrap)" \
     = "default
flake-shell-default"
test ! -e "$marker"

# With a command, nothing is loaded implicitly, as upstream.
test "$(cd "$project"; guix shell --bootstrap -- "$SHELL" -c 'echo "<$FLAKE_SHELL>"')" \
     = "<>"
