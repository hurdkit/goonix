# HS-6 root/build-user gate. The daemon runs as root only inside the guest.
{ pkgs ? import <nixpkgs> { }
, goonixDaemon
, guixClient ? pkgs.guix
, cxxDaemon ? pkgs.guix
}:

pkgs.testers.nixosTest {
  name = "goonix-hs6-build-users";
  nodes.machine = { pkgs, ... }:
    let staticBusybox = pkgs.pkgsStatic.busybox;
        # One static store item holds the busybox binary plus sh/id/sleep
        # symlinks to it.  BusyBox picks its applet from the invoked basename,
        # so the launcher and applets must be correctly-named symlinks inside a
        # single declared input, not hash-prefixed flat copies (a copy named
        # "<hash>-sh" reports "applet not found").  The whole item is the
        # derivation's input closure, so every symlink target is present in the
        # chroot.  The item is built with add-file-tree-to-store in each script.
        tools = staticBusybox; in {
    virtualisation.memorySize = 1024;
    users.groups.guixbuild = {
      gid = 31000;
      members = [ "guixbuilder01" "guixbuilder02" ];
    };
    users.groups.guixkvm.gid = 31001;
    users.users.guixbuilder01 = {
      isSystemUser = true;
      uid = 31002;
      group = "guixbuild";
      extraGroups = [ "guixkvm" ];
    };
    users.users.guixbuilder02 = {
      isSystemUser = true;
      uid = 31003;
      group = "guixbuild";
    };
    services.guix.enable = false;
    systemd.services.goonix-daemon = {
      description = "Goonix Haskell daemon build-user VM gate";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${goonixDaemon}/bin/guix-daemon --build-users-group=guixbuild --chroot-directory=/tmp/hs6-markers --substitute-urls=file:///tmp/hs6-substitutes --listen=/tmp/guix-daemon.sock";
        Environment = [
          "GUIX=${guixClient}/bin/guix"
          "GUIX_STATE_DIRECTORY=/var/guix"
          "GUIX_SANDBOX=${goonixDaemon}/bin/guix-sandbox"
          "GUIX_BINARY_SUBSTITUTE_URL=file:///tmp/hs6-substitutes"
          "GUIX_TEST_SUBSTITUTE_URLS=file:///tmp/hs6-substitutes"
          "GUIX_ALLOW_UNAUTHENTICATED_SUBSTITUTES=yes"
          "GUIX_LOG_DIRECTORY=/tmp/hs6-logs"
          "GUILE_LOAD_PATH=${guixClient}/share/guile/site/3.0"
          "GUILE_LOAD_COMPILED_PATH=${guixClient}/lib/guile/3.0/site-ccache"
        ];
        Restart = "no";
      };
    };
    environment.systemPackages = [ guixClient pkgs.guix pkgs.coreutils pkgs.guile pkgs.gawk pkgs.procps pkgs.sqlite ];
    environment.variables.GUILE_LOAD_PATH = "${guixClient}/share/guile/site/3.0";
    environment.variables.GUILE_LOAD_COMPILED_PATH = "${guixClient}/lib/guile/3.0/site-ccache";
    environment.variables.GUIX_BINARY_SUBSTITUTE_URL = "file:///tmp/hs6-substitutes";
    environment.variables.GUIX_TEST_SUBSTITUTE_URLS = "file:///tmp/hs6-substitutes";
    environment.variables.GUIX_STATE_DIRECTORY = "/var/guix";
    environment.etc."hs6-build-users.scm".text = ''
      (use-modules (guix store) (guix derivations) (ice-9 threads)
                   (ice-9 textual-ports))
      (define store (open-connection "/tmp/guix-daemon.sock"))
      (define markers "/tmp/hs6-markers")
      (define (marker name suffix) (string-append markers "/" name suffix))
      (set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
      ;; One static input item: the busybox binary plus sh/id/sleep symlinks to
      ;; it.  BusyBox selects its applet from the invoked basename, so flat
      ;; hash-prefixed copies ("<hash>-sh") fail with "applet not found"; the
      ;; launcher and applets must be correctly-named symlinks in one declared
      ;; input whose whole closure is mounted in the chroot.
      (define tools (add-file-tree-to-store store
                      `("hs6-static-tools" directory
                         ("busybox" executable (file "${tools}/bin/busybox"))
                         ("sh" symlink "busybox")
                         ("id" symlink "busybox")
                         ("cat" symlink "busybox")
                         ("sleep" symlink "busybox"))))
      (define shell (string-append tools "/sh"))
      (define id (string-append tools "/id"))
      (define cat (string-append tools "/cat"))
      (define sleep (string-append tools "/sleep"))
      (define (make-drv name)
        (let ((builder
               (add-text-to-store store (string-append name ".sh")
                 (string-append
                   "{ printf '=== " name " passwd ===\\n'; " cat " /etc/passwd; printf '=== group ===\\n'; " cat " /etc/group; printf '=== proc status Uid/Gid ===\\n'; " cat " /proc/self/status; printf '=== id -u ===\\n'; " id " -u; printf '=== id -gn ===\\n'; " id " -gn; } > /tmp/hs6-markers/" name ".diag 2>&1 || true\n"
                   "printf '%s %s %s\\n' \"$(" id " -u)\" \"$(" id " -g)\" \"$(" id " -G)\" > \"$out\"\n"
                   "printf '%s\\n' \"$out\" > /tmp/hs6-markers/" name ".started\n"
                   "while ! test -e /tmp/hs6-markers/" name ".release; do " sleep " 1; done\n"))))
          (derivation store name shell (list "-e" builder)
                      #:sources (list tools builder))))
      (define one (make-drv "hs6-one"))
      (define two (make-drv "hs6-two"))
      (call-with-output-file "/tmp/hs6-client.ready" (lambda (p) (display "ready\n" p)))
      (build-derivations store (list one two))
      (for-each (lambda (name drv)
                  (let ((output (derivation->output-path drv)))
                    (unless (valid-path? store output) (error "missing output" output))
                    (call-with-output-file (string-append "/tmp/hs6-" name ".output")
                      (lambda (port) (display output port)))
                    (call-with-output-file (string-append "/tmp/hs6-" name ".identity")
                      (lambda (port) (display (call-with-input-file output get-string-all) port)))))
                (list "one" "two") (list one two))
      (call-with-output-file "/tmp/hs6-client.done" (lambda (p) (display "done\n" p)))
      (close-connection store)
    '';
    environment.etc."hs6-cleanup.scm".text = ''
      (use-modules (guix store) (guix derivations) (ice-9 textual-ports))
      (define store (open-connection "/tmp/guix-daemon.sock"))
      (set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
      (define tools (add-file-tree-to-store store
                      `("hs6-static-tools" directory
                         ("busybox" executable (file "${tools}/bin/busybox"))
                         ("sh" symlink "busybox")
                         ("id" symlink "busybox")
                         ("sleep" symlink "busybox"))))
      (define shell (string-append tools "/sh"))
      (define id (string-append tools "/id"))
      (define sleep (string-append tools "/sleep"))
      (define (make-drv name leave-process?)
        (let ((builder
               (add-text-to-store store (string-append name ".sh")
                 (string-append
                   "printf '%s %s %s\\n' \"$(" id " -u)\" \"$(" id " -g)\" \"$(" id " -G)\" > \"$out\"\n"
                   "printf '%s\\n' \"$out\" > /tmp/hs6-markers/" name ".started\n"
                   (if leave-process?
                     (string-append
                       sleep " 300 </dev/null >/dev/null 2>&1 &\n"
                       "printf '%s\\n' $! > /tmp/hs6-markers/hs6-leftover.pid\n")
                     "")
                   "while ! test -e /tmp/hs6-markers/" name ".release; do " sleep " 1; done\n"))))
          (derivation store name shell (list "-e" builder)
                      #:sources (list tools builder))))
      (define first (make-drv "hs6-leave-process" #t))
      (define second (make-drv "hs6-reuse" #f))
      (build-derivations store (list first))
      (call-with-output-file "/tmp/hs6-first.identity"
        (lambda (port) (display (call-with-input-file (derivation->output-path first) get-string-all) port)))
      (call-with-output-file "/tmp/hs6-first.done" (lambda (port) (display "done\n" port)))
      (build-derivations store (list second))
      (call-with-output-file "/tmp/hs6-second.identity"
        (lambda (port) (display (call-with-input-file (derivation->output-path second) get-string-all) port)))
      (call-with-output-file "/tmp/hs6-cleanup.done" (lambda (p) (display "done\n" p)))
      (close-connection store)
    '';
    environment.etc."hs6-reverse-exclusion.scm".text = ''
      (use-modules (guix store) (guix derivations) (ice-9 threads)
                   (ice-9 textual-ports) (srfi srfi-13) (srfi srfi-34))
      (define store (open-connection "/tmp/guix-daemon.sock"))
      (define tools (add-file-tree-to-store store
                      `("hs6-static-tools" directory
                         ("busybox" executable (file "${tools}/bin/busybox"))
                         ("sh" symlink "busybox")
                         ("id" symlink "busybox")
                         ("sleep" symlink "busybox"))))
      (define shell (string-append tools "/sh"))
      (define id (string-append tools "/id"))
      (define sleep (string-append tools "/sleep"))
      (define (make-drv name)
        (let ((builder (add-text-to-store store (string-append name ".sh")
                 (string-append "printf '%s\\n' \"$(" id " -u)\" >$out\n"
                                "printf 'started %s\\n' \"$(" id " -u)\" > /tmp/hs6-markers/" name ".rstarted\n"
                                "while ! test -e /tmp/hs6-markers/reverse.release; do " sleep " 1; done\n"
                                "printf 'exited\\n' > /tmp/hs6-markers/" name ".rexited\n"))))
          (derivation store name shell (list "-e" builder)
                      #:sources (list tools builder))))
      (define one (make-drv "hs6-reverse-one"))
      (define two (make-drv "hs6-reverse-two"))
      (set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2 #:keep-going? #t)
      ;; One of the two leases succeeds; the other must be rejected with "all
      ;; build users are currently in use" while C++ holds the remaining user.
      ;; keep-going lets the successful builder finish; the RPC reports the
      ;; failure only after every goal is done, so record the caught message and
      ;; let the test release the survivor before waiting for it.
      (guard (condition ((store-protocol-error? condition)
                         (let ((message (store-protocol-error-message condition)))
                           (call-with-output-file "/tmp/hs6-reverse.error"
                             (lambda (port) (display message port)))
                           (unless (string-contains message
                                                    "all build users are currently in use")
                             (raise condition)))))
        (build-derivations store (list one two))
        (call-with-output-file "/tmp/hs6-reverse.returned"
          (lambda (port) (display "build-derivations returned without error\n" port))))
      (call-with-output-file "/tmp/hs6-reverse.identities"
        (lambda (port)
          (for-each (lambda (drv)
                      (let ((output (derivation->output-path drv)))
                        (when (valid-path? store output)
                          (display (call-with-input-file output get-string-all) port))))
                    (list one two))))
      (close-connection store)
    '';
    environment.etc."hs6-substitute-collect.scm".text = ''
      (use-modules (guix store) (guix derivations) (guix tests)
                   (ice-9 textual-ports) (srfi srfi-11))
      (define (assert condition message)
        (unless condition (error message)))
      (define store (open-connection "/tmp/guix-daemon.sock"))
      (define drv (derivation store "hs6-substituted" "/does-not-exist" '()))
      (define output (derivation->output-path drv))
      (define root "/tmp/hs6-markers/substitute-root")
      (set-build-options store #:use-substitutes? #t #:fallback? #f
                         #:substitute-urls (%test-substitute-urls))
      (with-derivation-substitute drv "root-substituted-output\n"
        (ensure-path store output))
      (assert (valid-path? store output) "substitute did not register output")
      (assert (string=? "root-substituted-output\n"
                        (call-with-input-file output get-string-all))
              "substitute content differs")
      (symlink output root)
      (add-indirect-root store root)
      (let-values (((paths freed) (collect-garbage store)))
        (assert (file-exists? output) "collection deleted rooted substitute")
        (assert (valid-path? store output) "collection invalidated rooted substitute"))
      (assert (= 0 (stat:uid (stat output))) "substitute is not root-owned")
      (call-with-output-file "/tmp/hs6-substitute.path"
        (lambda (port) (display output port)))
      (call-with-output-file "/tmp/hs6-substitute-collect.done"
        (lambda (port) (display "done\n" port)))
      (close-connection store)
    '';
    environment.etc."hs6-exclusion.scm".text = ''
      (use-modules (guix store) (guix derivations))
      (define store (open-connection "/tmp/cxx-daemon.sock"))
      (set-build-options store #:use-substitutes? #f #:offload? #f #:max-build-jobs 2)
      (define tools (add-file-tree-to-store store
                      `("hs6-static-tools" directory
                         ("busybox" executable (file "${tools}/bin/busybox"))
                         ("sh" symlink "busybox")
                         ("id" symlink "busybox")
                         ("sleep" symlink "busybox"))))
      (define shell (string-append tools "/sh"))
      (define sleep (string-append tools "/sleep"))
      (define id (string-append tools "/id"))
      (define builder
        (add-text-to-store store "hs6-exclusion.sh"
          (string-append
            "printf '%s\\n' \"$(" id " -u)\" >/tmp/cxx-markers/exclusion.uid\n"
            "while ! test -e /tmp/cxx-markers/exclusion.release; do " sleep " 1; done\n")))
      (build-derivations store (list (derivation store "hs6-exclusion" shell (list "-e" builder) #:sources (list tools builder))))
    '';
  };
  testScript = ''
    machine.wait_for_unit("goonix-daemon.service")
    machine.succeed("test -S /tmp/guix-daemon.sock")
    machine.succeed("test \"$(id -u guixbuilder01)\" = 31002")
    machine.succeed("test \"$(id -u guixbuilder02)\" = 31003")
    machine.succeed("mkdir -p /tmp/hs6-markers /tmp/cxx-markers /tmp/hs6-substitutes && chmod 1777 /tmp/hs6-markers /tmp/cxx-markers")
    try:
        machine.succeed("guix repl -- /etc/hs6-substitute-collect.scm >/tmp/hs6-substitute-collect.log 2>&1")
    except Exception:
        machine.succeed("cat /tmp/hs6-substitute-collect.log; journalctl -u goonix-daemon.service --no-pager; find /tmp/hs6-substitutes -maxdepth 1 -type f -print; false")
        raise
    machine.wait_for_file("/tmp/hs6-substitute-collect.done")
    machine.succeed("test -f /var/guix/db/db.sqlite")
    machine.succeed("sqlite3 /var/guix/db/db.sqlite \"pragma busy_timeout=10000; select name from sqlite_master where type='table'\" | grep -q '^ValidPaths$'")
    machine.succeed("test \"$(stat -c %u:%g \"$(cat /tmp/hs6-substitute.path)\")\" = 0:0")
    machine.succeed("output=$(cat /tmp/hs6-substitute.path); stat -c '%u:%g %a %A %n' \"$output\"; case $(stat -c %a \"$output\") in *[2367]*) exit 1;; esac")
    machine.succeed("systemctl show goonix-daemon.service -p Environment -p ExecStart")
    machine.succeed("guix repl -- /etc/hs6-build-users.scm >/tmp/hs6-client.log 2>&1 &")
    machine.wait_for_file("/tmp/hs6-client.ready")
    for name in ("one", "two"):
        with machine.nested(f"waiting for builder {name} or client failure"):
            try:
                machine.wait_for_file(f"/tmp/hs6-markers/hs6-{name}.started", timeout=45)
            except Exception:
                machine.succeed("cat /tmp/hs6-client.log; journalctl -u goonix-daemon.service --no-pager; test ! -d /tmp/hs6-logs || find /tmp/hs6-logs -type f -exec sh -c 'echo --- $1; zcat $1' sh {} \\;; false")
                raise
    machine.log("=== hs6 ps ===\n" + machine.succeed("ps -eo uid,gid,stat,args"))
    machine.log("=== hs6 journal ===\n" + machine.succeed("journalctl -u goonix-daemon.service --no-pager"))
    machine.log("=== hs6 client log ===\n" + machine.succeed("cat /tmp/hs6-client.log"))
    machine.log("=== hs6 build logs ===\n" + machine.succeed("test ! -d /tmp/hs6-logs || find /tmp/hs6-logs -type f -exec sh -c 'echo --- $1; zcat $1' sh {} \\;"))
    machine.log("=== hs6 builder diag ===\n" + machine.succeed("cat /tmp/hs6-markers/hs6-one.diag /tmp/hs6-markers/hs6-two.diag 2>/dev/null || true"))
    # Which uid a derivation gets is not the daemon's promise: UserLock takes
    # the first free group member, and the order of two concurrent goals is not
    # fixed.  Require each builder under a build-group uid, and the two differ.
    machine.succeed("one=$(ps -eo uid=,args= | awk '/hs6-one\\.sh/ {print $1; exit}'); two=$(ps -eo uid=,args= | awk '/hs6-two\\.sh/ {print $1; exit}'); test -n \"$one\"; test -n \"$two\"; test \"$one\" != \"$two\"; { test \"$one\" = 31002 || test \"$one\" = 31003; }; { test \"$two\" = 31002 || test \"$two\" = 31003; }")
    # In the chroot, id -u must return the leased uid and id -gn the build
    # group's name as written in /etc/passwd and /etc/group ("nixbld", as C++).
    machine.succeed("for n in one two; do d=/tmp/hs6-markers/hs6-$n.diag; u=$(ps -eo uid=,args= | awk -v p=\"hs6-$n\\\\.sh\" '$0 ~ p {print $1; exit}'); test \"$(sed -n '/=== id -u ===/{n;p;}' \"$d\")\" = \"$u\"; test \"$(sed -n '/=== id -gn ===/{n;p;}' \"$d\")\" = nixbld; done")
    # C++ must skip both UIDs already leased by the Haskell daemon.
    machine.succeed("GUIX_STATE_DIRECTORY=/var/guix GUIX_LOG_DIRECTORY=/tmp/cxx-var/log/guix GUIX_DAEMON_SOCKET=/tmp/cxx-daemon.sock ${cxxDaemon}/bin/guix-daemon --build-users-group=guixbuild --disable-chroot --no-substitutes --listen=/tmp/cxx-daemon.sock >/tmp/cxx-daemon.log 2>&1 &")
    machine.succeed("for i in $(seq 1 100); do test -S /tmp/cxx-daemon.sock && break; sleep .1; done; test -S /tmp/cxx-daemon.sock")
    machine.succeed("GUIX_DAEMON_SOCKET=/tmp/cxx-daemon.sock guix repl -- /etc/hs6-exclusion.scm >/tmp/cxx-client.log 2>&1 &")
    machine.wait_for_file("/tmp/cxx-daemon.log")
    machine.wait_until_succeeds("grep -q 'all build users are currently in use' /tmp/cxx-client.log")
    # The first exhaustion check is done with both Haskell builders holding the
    # two users.  Release them and verify their identities before the reverse
    # exclusion, which needs C++ to lease one user while Haskell leases the
    # other (so both users must be free again).
    machine.succeed("pkill -f 'guix-daemon.*cxx-daemon.[s]ock' || true")
    machine.succeed("touch /tmp/hs6-markers/hs6-one.release /tmp/hs6-markers/hs6-two.release")
    machine.log("=== after release: client log ===\n" + machine.succeed("sleep 5; cat /tmp/hs6-client.log 2>/dev/null || true"))
    machine.log("=== after release: builders/markers ===\n" + machine.succeed("ps -eo uid,pid,stat,args | grep -E 'hs6|guix-daemon|guile' | grep -v grep; ls -la /tmp/hs6-markers/ /tmp/hs6-client.done /tmp/hs6-one.identity /tmp/hs6-two.identity 2>&1 || true"))
    machine.log("=== after release: journal ===\n" + machine.succeed("journalctl -u goonix-daemon.service --no-pager | tail -20"))
    machine.wait_for_file("/tmp/hs6-client.done")
    machine.succeed("cat /tmp/hs6-client.log")
    machine.succeed("cat /tmp/hs6-*.identity")
    # Each identity file carries its own builder's uid (either group member),
    # the build group's gid, and the two uids differ.  The kvm supplementary
    # group (31001) belongs to guixbuilder01, so exactly one file lists it.
    machine.succeed("u1=$(awk '{print $1; exit}' /tmp/hs6-one.identity); u2=$(awk '{print $1; exit}' /tmp/hs6-two.identity); test \"$u1\" != \"$u2\"; { test \"$u1\" = 31002 || test \"$u1\" = 31003; }; { test \"$u2\" = 31002 || test \"$u2\" = 31003; }; grep -q \"^$u1 31000 \" /tmp/hs6-one.identity; grep -q \"^$u2 31000 \" /tmp/hs6-two.identity; test \"$(grep -l '31001' /tmp/hs6-one.identity /tmp/hs6-two.identity | wc -l)\" = 1")
    machine.succeed("ps -eo uid=,stat= | awk '$1 == 31002 || $1 == 31003 { if ($2 !~ /^Z/) found = 1 } END { exit found ? 1 : 0 }'")
    machine.succeed("for record in /tmp/hs6-one.output /tmp/hs6-two.output; do output=$(cat \"$record\"); stat -c '%u:%g %a %A %n' \"$output\"; test \"$(stat -c %u:%g \"$output\")\" = 0:0; case $(stat -c %a \"$output\") in *[2367]*) exit 1;; esac; done")
    machine.succeed("test -e /var/guix/userpool/31002 -a -e /var/guix/userpool/31003")
    # Reverse exclusion: C++ leases one user and keeps its builder alive while
    # Haskell leases the other and rejects a second concurrent lease.
    machine.succeed("rm -f /tmp/cxx-daemon.sock /tmp/cxx-client.log /tmp/cxx-daemon.log /tmp/cxx-markers/exclusion.uid /tmp/cxx-markers/exclusion.release")
    machine.succeed("GUIX_STATE_DIRECTORY=/var/guix GUIX_LOG_DIRECTORY=/tmp/cxx-var/log/guix GUIX_DAEMON_SOCKET=/tmp/cxx-daemon.sock ${cxxDaemon}/bin/guix-daemon --build-users-group=guixbuild --disable-chroot --no-substitutes --listen=/tmp/cxx-daemon.sock >/tmp/cxx-daemon.log 2>&1 &")
    machine.succeed("for i in $(seq 1 100); do test -S /tmp/cxx-daemon.sock && break; sleep .1; done; test -S /tmp/cxx-daemon.sock")
    machine.succeed("GUIX_DAEMON_SOCKET=/tmp/cxx-daemon.sock guix repl -- /etc/hs6-exclusion.scm >/tmp/cxx-client.log 2>&1 &")
    machine.wait_for_file("/tmp/cxx-markers/exclusion.uid")
    machine.succeed("test \"$(cat /tmp/cxx-markers/exclusion.uid)\" = 31002 -o \"$(cat /tmp/cxx-markers/exclusion.uid)\" = 31003")
    # While C++ holds one user, Haskell must use the other and reject a second
    # concurrent lease rather than taking the C++ user's UID.
    machine.succeed("guix repl -- /etc/hs6-reverse-exclusion.scm >/tmp/hs6-reverse.log 2>&1 &")
    # Match the builder script (sh -e .../hs6-reverse-*.sh), not the test
    # driver's own grep command line, which also contains these names.
    machine.succeed("for i in $(seq 1 100); do ps -eo uid=,args= | awk '$1 == 31002 || $1 == 31003' | grep -q 'hs6-reverse-one\\.sh\\|hs6-reverse-two\\.sh' && break; sleep .1; done")
    machine.succeed("ps -eo uid=,args= | awk '$1 == 31002 || $1 == 31003' | grep 'hs6-reverse-one\\.sh\\|hs6-reverse-two\\.sh' >/tmp/hs6-reverse.ps")
    machine.succeed("test \"$(awk '{ count[$1]++ } END { for (uid in count) print uid }' /tmp/hs6-reverse.ps)\" != \"$(cat /tmp/cxx-markers/exclusion.uid)\"")
    # keep-going delivers the rejected lease's error only after the survivor
    # finishes, and the survivor waits on reverse.release.  Release it first,
    # then require the recorded exhaustion message (the client catches the RPC
    # error and writes it to hs6-reverse.error rather than printing it).
    machine.succeed("touch /tmp/hs6-markers/reverse.release")
    # Bounded wait: if the keep-going RPC has not delivered the caught error in
    # 60 s, dump builder markers, client log, processes and journal so the hang
    # is diagnosable rather than a bare 900 s timeout.  The test driver wraps
    # every command in `set -euo pipefail`, so each fallible step needs || true.
    machine.succeed("for i in $(seq 1 60); do test -e /tmp/hs6-reverse.error && break; sleep 1; done; true")
    machine.log("=== reverse diag: markers ===\n" + machine.succeed("ls -la /tmp/hs6-markers/ 2>&1 || true; for f in /tmp/hs6-markers/hs6-reverse-*.rstarted /tmp/hs6-markers/hs6-reverse-*.rexited /tmp/hs6-reverse.error /tmp/hs6-reverse.returned /tmp/hs6-reverse.identities; do echo \"--- $f\"; cat \"$f\" 2>&1 || true; done"))
    machine.log("=== reverse diag: reverse.ps ===\n" + machine.succeed("cat /tmp/hs6-reverse.ps 2>&1 || true"))
    machine.log("=== reverse diag: client log ===\n" + machine.succeed("cat /tmp/hs6-reverse.log 2>&1 || true"))
    machine.log("=== reverse diag: ps ===\n" + machine.succeed("ps -eo uid,pid,stat,args | grep -E 'hs6-reverse|guix-daemon|guile|guix-sandbox' | grep -v grep || true"))
    machine.log("=== reverse diag: build logs ===\n" + machine.succeed("if test -d /tmp/hs6-logs; then find /tmp/hs6-logs -type f -exec sh -c 'echo --- $1; zcat $1 2>&1 || true' sh {} \\;; fi"))
    machine.log("=== reverse diag: journal ===\n" + machine.succeed("journalctl -u goonix-daemon.service --no-pager | tail -40 || true"))
    machine.succeed("test -e /tmp/hs6-reverse.error")
    machine.succeed("grep -q 'all build users are currently in use' /tmp/hs6-reverse.error")
    machine.wait_for_file("/tmp/hs6-reverse.identities")
    machine.succeed("test \"$(cat /tmp/hs6-reverse.identities | wc -l)\" = 1")
    machine.succeed("touch /tmp/cxx-markers/exclusion.release")
    machine.succeed("pkill -f 'guix-daemon.*cxx-daemon.[s]ock' || true")
    machine.succeed("guix repl -- /etc/hs6-cleanup.scm >/tmp/hs6-cleanup.log 2>&1 &")
    machine.wait_for_file("/tmp/hs6-markers/hs6-leftover.pid")
    machine.wait_for_file("/tmp/hs6-markers/hs6-leave-process.started")
    # The leftover sleep runs in the builder's PID namespace, so $! records a
    # namespace-local pid (e.g. 5), not a host pid.  Identify it by its command
    # line under a build-group uid instead.  Require exactly one such process.
    machine.succeed("ps -eo uid=,pid=,args= | awk '$1 == 31002 || $1 == 31003' | grep 'sleep 300' >/tmp/hs6-leftover.ps")
    machine.succeed("test \"$(wc -l </tmp/hs6-leftover.ps)\" = 1")
    machine.succeed("uid=$(awk '{print $1; exit}' /tmp/hs6-leftover.ps); test \"$uid\" = 31002 -o \"$uid\" = 31003; printf '%s\n' \"$uid\" >/tmp/hs6-reuse.uid")
    machine.succeed("touch /tmp/hs6-markers/hs6-leave-process.release")
    machine.wait_for_file("/tmp/hs6-first.done")
    # After the lease releases, the daemon's killUser sweep must have killed the
    # leftover sleep: no build-group uid may own a 'sleep 300' process anymore.
    machine.succeed("! ps -eo uid=,args= | awk '$1 == 31002 || $1 == 31003' | grep -q 'sleep 300'")
    machine.wait_for_file("/tmp/hs6-markers/hs6-reuse.started")
    machine.succeed("touch /tmp/hs6-markers/hs6-reuse.release")
    machine.wait_for_file("/tmp/hs6-cleanup.done")
    machine.succeed("cat /tmp/hs6-first.identity /tmp/hs6-second.identity")
    # The first build's uid is the leftover's uid (the lease that owned the
    # leftover sleep).  Which uid the SECOND sequential build gets is not the
    # daemon's promise: C++ UserLock takes the first free group member in
    # getgrnam order, and the Haskell pool rotates, so after the first lease
    # releases the second build may take either member.  Require the first
    # identity to match the leftover uid, and the second to be a build-group
    # uid with the build group's gid (not necessarily the same uid).
    machine.succeed("test \"$(cut -d' ' -f1 /tmp/hs6-first.identity)\" = \"$(cat /tmp/hs6-reuse.uid)\"")
    machine.succeed("u2=$(cut -d' ' -f1 /tmp/hs6-second.identity); test \"$u2\" = 31002 -o \"$u2\" = 31003; grep -q \"^$u2 31000 \" /tmp/hs6-second.identity")
    machine.succeed("ps -eo uid=,stat= | awk '$1 == 31002 || $1 == 31003 { if ($2 !~ /^Z/) found = 1 } END { exit found ? 1 : 0 }'")
  '';
}
