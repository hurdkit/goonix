// goonix: the worker operations that upstream's daemon does not have.
//
// nix-daemon.cc includes this file before performOp, which calls
// goonixPerformOp for an operation it does not know.  It is not a
// translation unit of its own because the operations report their work
// through that file's startWork and stopWork.

#include "misc.hh" // derivationFromPath, for the realised-output query

/* Perform OP and return true if OP is an operation of goonix.  Otherwise
   read nothing, write nothing and return false: the caller then refuses OP
   as upstream's daemon refuses an operation that it does not have.  */
static bool goonixPerformOp(Source & from, Sink & to, unsigned int op)
{
    switch (op) {

    case wopQueryRealisedOutput: {
        /* No choice mutation in a query and no client registration.  */
        Path drv = readStorePathStrict(from);
        string output = readString(from);
        startWork();
        Path path = dynamic_cast<LocalStore *>(store.get())
            ->realisedOutputPath(drv, derivationFromPath(*store, drv), output);
        stopWork();
        writeString(path, to);
        break;
    }

    case wopQueryBuildRecords: {
        string hash = readString(from);
        string output = readString(from);
        startWork();
        auto records = dynamic_cast<LocalStore *>(store.get())
            ->queryGoonixBuildRecords(hash, output);
        stopWork();
        /* One list of strings, six per record: a type that the client's
           (guix serialization) has, so that the module stays upstream's.
           Its text is part of the derivations of most packages.  */
        writeStrings(goonixRecordFields(records), to);
        break;
    }

    case wopQueryBuildGraph: {
        /* Read-only graph facts; clients cannot register mappings.  */
        Path drv = readStorePathStrict(from);
        startWork();
        auto response = dynamic_cast<LocalStore *>(store.get())
            ->queryGoonixBuildGraph(drv);
        stopWork();
        writeStrings(goonixRecordFields(response.first, true), to);
        writeStrings(response.second, to); // record-backed unsigned hints
        break;
    }

    case wopQuerySessions:
        /* Local clients only, as the Haskell daemon: the PIDs of the
           answer mean nothing on another host.  */
        if (isRemoteConnection) return false;
        startWork();
        stopWork();
        writeStrings(goonixSessionReport(), to);
        break;

    default:
        return false;
    }

    return true;
}
