# HS-9 Hurd guest runtime probe

A threaded Haskell program for `x86_64-pc-gnu` that exercises the five runtime
facilities the Haskell daemon needs on the Hurd guest (00-plan.md §7,
DECISIONS.md point 5):

1. **Threaded runtime** — `forkOS` and `forkIO` threads run with distinct ids.
2. **Timer** — `threadDelay` waits and returns.
3. **Poll on a socket** — `threadWaitRead` + `fdRead` on a Unix-domain
   `socketpair` fd, the same I/O-manager poll path the daemon uses in
   `Goonix.Store.Socket`.
4. **Child process** — `System.Process.readProcess` spawns `/bin/sh -c`.
5. **STM** — an `atomically`/`retry` exchange between two threads, plus a
   `registerDelay` timeout that wakes a retrying transaction (DECISIONS.md
   point 5, "STM on the Hurd").

Only boot libraries are used (`base`, `unix`, `process`, `stm`, `bytestring`)
plus a two-line C `socketpair` helper, so it builds with the daemon's own
toolchain and needs no Hackage packages.

## Build and run

```sh
ghc -threaded -rtsopts -with-rtsopts=-N -O2 HurdRuntimeProbe.hs socketpair.c
./HurdRuntimeProbe +RTS -N2
```

Or `bash gate.sh [GHC]`. It prints one `PASS <label>` line per facility and
`ALL PASS`, exiting 0 only if every check passes.

## Status

- **Host (Linux):** builds and runs `ALL PASS` (2026-11-21, GHC 9.10.3). This
  validates the probe's logic only.
- **Guest (Hurd):** the gate. It cannot run yet because no GHC targeting
  `x86_64-pc-gnu` exists; see STATUS.md "HS-9: Hurd guest — compiler probe (E4)"
  for the precise packaging gap (the GHC package's `set-target-programs` wires
  the host gcc, not the cross gcc; hadrian is given no cross target). The Debian
  native route (registerised GHC 9.6 on hurd-amd64) is the known-working
  alternative. When a Hurd compiler exists, run this probe in the guest; H6
  keeps the guest on the C++ daemon until then.