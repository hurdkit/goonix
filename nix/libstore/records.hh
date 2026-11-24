// goonix: permanent build records and local output choices.
#pragma once

#include "types.hh"
#include "sqlite.hh"
#include <map>
#include <vector>

namespace nix {

struct BuildRecord {
    string resolvedHash;
    Path resolvedDerivation;
    string output;
    Path path;
    string origin;
    bool relocationChecked = false;
    string signature;
};

/* A recorded disagreement: two different results for one resolved
   derivation/output.  This is the reproducibility signal (plan 3.3, 10). */
struct RecordConflict {
    string resolvedHash;
    string output;
    Path pathA;
    Path pathB;
    string origin;
};

/* Domain-separated, length-prefixed bytes of every signed record field. */
string canonicalBuildRecordPayload(const BuildRecord & record);
Strings goonixRecordFields(const std::vector<BuildRecord> & records,
    bool includeHash = false);

typedef std::map<std::pair<Path, string>, Path> OutputChoices;

/* Permanent facts and local choices.  Deliberately independent of store
   rows: neither is lost when a .drv or an output is collected. */
class BuildRecords {
    sqlite3 * db;
public:
    BuildRecords(sqlite3 * db);
    void initialise();
    SQLiteTxn transaction();
    void add(const BuildRecord & record);
    std::vector<BuildRecord> query(const string & resolvedHash,
        const string & output = "");
    /* Facts indexed by the realised output path, for collector reachability
       and for walking a build graph bottom-up (plan 7, 10). */
    std::vector<BuildRecord> queryByPath(const Path & path);
    std::vector<BuildRecord> queryByResolvedDerivation(const Path & resolved);
    PathSet derivationsForPath(const Path & path);
    PathSet originalsForPath(const Path & path);
    PathSet chosenPaths(const Path & unresolved);
    std::vector<RecordConflict> conflicts(const string & resolvedHash,
        const string & output = "");
    void choose(const Path & unresolved, const string & output,
        const Path & realised);
    /* Forced replacement of a choice, used only on purpose: a stale
       (collected) choice being repaired, or an explicit policy adoption. */
    void rechoose(const Path & unresolved, const string & output,
        const Path & realised);
    Path choice(const Path & unresolved, const string & output);
    OutputChoices choices(const Path & unresolved);
    void drop(const Path & unresolved, const string & output); // goonix: stale graph promise
};

}