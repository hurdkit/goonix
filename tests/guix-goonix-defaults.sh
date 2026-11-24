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
# goonix: commands of upstream Guix keep their behaviour when none of
# goonix's options is given.
#

set -e

guix system --version

errors="t-goonix-defaults-errors-$$"
trap 'rm -f "$errors"' EXIT

# 'guix system ACTION -e EXPRESSION' takes no file argument.  The expression
# is evaluated, and the complaint is about its value.
if guix system build -e 42 2> "$errors"
then false
fi
cat "$errors"
grep "does not return an operating system" "$errors"

# Without a file and without an expression the complaint is upstream's.
if guix system build 2> "$errors"
then false
fi
cat "$errors"
grep "wrong number of arguments" "$errors"
