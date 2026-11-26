# goonix: 'guix processes' and the daemon it asks for its sessions.
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
# 'guix processes' asks the daemon for its sessions.  A daemon that is asked
# for an operation it does not have ends the session that asked and writes
# "invalid operation" on its standard error.  This runs a daemon whose
# standard error is kept, lists its sessions in both formats from a client
# that is connected to it, and checks that the daemon was asked nothing it
# refused, that the client's session is listed, and that it is printed with a
# number exactly when the daemon serves it from the process that listens.
#

set -e

guix processes --version

work="t-guix-processes-$$"
socket="$GUIX_STATE_DIRECTORY/processes-socket"
rm -rf "$work"
mkdir "$work"

guix-daemon --no-substitutes --listen="$socket" --disable-chroot \
	    2> "$work/daemon.log" &
daemon_pid=$!
trap 'kill $daemon_pid; rm -rf "$work"' EXIT

tries=0
until test -S "$socket"
do
    kill -0 "$daemon_pid"
    tries=$((tries + 1))
    test "$tries" -lt 600
    sleep 0.1
done

GUIX_DAEMON_SOCKET="$socket" work="$work" guile -c '
  (use-modules (guix store) (guix scripts processes))
  (define (in-work name) (string-append (getenv "work") "/" name))
  (with-store store
    (call-with-output-file (in-work "client")
      (lambda (port) (display (getpid) port)))
    (with-output-to-file (in-work "recutils")
      (lambda () (guix-processes)))
    (with-output-to-file (in-work "normalized")
      (lambda () (guix-processes "--format=normalized"))))'

client="`cat "$work/client"`"
test -n "$client"

# The daemon was asked nothing that it refused.
if grep -i "invalid operation" "$work/daemon.log"
then false
else true
fi

# The session of the client is listed, in both formats.
grep -x "ClientPID: $client" "$work/recutils"
grep -x "ClientPID: $client" "$work/normalized"

session="`grep -B2 -x "ClientPID: $client" "$work/recutils" \
	  | sed -n 's/^SessionPID: //p' | tail -n 1`"
test -n "$session"

if test "$session" = "$daemon_pid"
then
    # A session of the process that listens: only the daemon knew it.  It
    # has a number, and that number is part of its key.
    number="`grep -B1 -x "ClientPID: $client" "$work/recutils" \
	     | sed -n 's/^SessionNumber: //p'`"
    test -n "$number"
    grep -x "PID: $daemon_pid-$number" "$work/normalized"
else
    # A session with a process of its own, read in /proc: printed as
    # upstream prints it, without a number.
    test "`grep -B1 -x "ClientPID: $client" "$work/recutils" | head -n 1`" \
	 = "SessionPID: $session"
    grep -x "PID: $session" "$work/normalized"
    if grep -A3 -x "SessionPID: $session" "$work/recutils" \
	    | grep "^SessionNumber:"
    then false
    else true
    fi
fi
