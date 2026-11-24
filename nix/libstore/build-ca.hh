// goonix: plain-data and filesystem helpers for upstream build scheduler hooks.
#pragma once
#include "types.hh"
#include "store-api.hh"
#include "derivations.hh"
#include "local-store.hh"
#include <functional>
#include <map>
#include <vector>

namespace nix {

struct GoonixBuildKind { bool fixedOutput; unsigned int rounds; };
GoonixBuildKind goonixBuildKind(const Derivation & drv, unsigned int repeat);

struct GoonixResolvedState {
    Derivation drv;
    Path resolvedPath;
    bool allRealised = false;
};
GoonixResolvedState prepareResolvedBuild(LocalStore & store,
    const Path & originalPath, const Derivation & original,
    const Derivation & resolved, BuildMode mode);
enum class GoonixGoalAction { ordinary, done, build, substituteInputs, substituteOutputs };
struct GoonixGoalState {
    Derivation drv;
    Path originalPath;
    Path resolvedPath;
    PathSet inputPaths;
    PathSet allPaths;
    PathSet missingPaths;
    bool fixedOutput = false;
    unsigned int rounds = 0;
    GoonixGoalAction action = GoonixGoalAction::ordinary;
};
GoonixGoalState prepareGoonixGoal(LocalStore & store, const Path & path,
    const Path & originalPath, const Derivation & input,
    const Derivation & original, BuildMode mode, unsigned int repeat);
GoonixResolvedState resolveGoonixBuild(LocalStore & store,
    const Path & originalPath, const Derivation & original);
bool goonixBuildAlreadyRealised(LocalStore & store, const Path & originalPath,
    const Derivation & drv);
void selectGoonixOutputs(LocalStore & store, const Path & originalPath,
    Derivation & drv);
void goonixInputPaths(StoreAPI & store, const Derivation & drv,
    PathSet & inputPaths, PathSet & allPaths);

void removeGoonixEnvironment(StringPairs & environment);
void materialiseGoonixFiles(const Derivation & drv, Strings & arguments,
    const Path & hostDirectory, const Path & sandboxDirectory);

void checkGoonixReferences(StoreAPI & store, const Derivation & drv,
    const Path & path, const Path & token,
    const std::map<Path, Path> & finalOutputs, const PathSet & references);

struct GoonixOutputContext {
    LocalStore & store;
    const Derivation & drv;
    const Derivation & original;
    const Path & resolvedPath;
    const Path & originalPath;
    const PathSet & allPaths;
    const PathSet & missingPaths;
    bool useChroot;
    const Path & chrootRoot;
    BuildMode mode;
    uid_t uid;
    gid_t gid;
    std::function<void(const Path &)> canonicalise;
    std::function<void()> cleanup;
};
struct GoonixOutputResult {
    bool check = false;
    ValidPathInfos infos;
    std::vector<std::pair<string, Path>> facts;
    std::map<Path, Path> finalOutputs;
    PathSet stagedOutputs;
};
GoonixOutputResult finaliseGoonixOutputs(LocalStore & store,
    Derivation & drv, const Derivation & original, const Path & resolvedPath,
    const Path & originalPath, const PathSet & allPaths,
    const PathSet & missingPaths, bool useChroot, const Path & chrootRoot,
    BuildMode mode, uid_t uid, gid_t gid, InodesSeen & inodesSeen,
    const std::function<void()> & cleanup);
void discardGoonixOutputs(StoreAPI & store, const GoonixOutputResult & result);
void recordGoonixOutput(LocalStore & store, const Path & originalPath,
    const Path & resolvedPath, const string & output, const Path & path,
    const string & origin);
void recordGoonixFacts(LocalStore & store, const Path & originalPath,
    const Path & resolvedPath,
    const std::vector<std::pair<string, Path>> & facts);

}
