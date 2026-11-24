// goonix: CA build-state transformations used by the upstream scheduler.
#include "build-ca.hh"
#include "ca.hh"
#include "deep-scan.hh"
#include "archive.hh"
#include "globals.hh"
#include "misc.hh"
#include <format>
#include <sstream>
#include <sys/stat.h>

namespace nix {

GoonixBuildKind goonixBuildKind(const Derivation & drv, unsigned int repeat)
{
    bool fixedOutput = true;
    for (auto & output : drv.outputs)
        if (output.second.hash.empty()) fixedOutput = false;
    return {fixedOutput, fixedOutput ? 1 : repeat + 1};
}

GoonixResolvedState prepareResolvedBuild(LocalStore & store,
    const Path & originalPath, const Derivation & original,
    const Derivation & resolved, BuildMode mode)
{
    Derivation drv = resolved;
    for (auto & choice : store.choices(originalPath)) store.addTempRoot(choice.second);
    const string resolvedHash = printHash(hashString(htSHA256, unparseDerivation(drv)));
    bool allRealised = true;
    for (auto & output : drv.outputs) {
        Path selected = store.selectGoonixOutput(originalPath,
            output.first, resolvedHash, "", false);
        if (!selected.empty()) {
            output.second.path = selected;
            if (mode == bmNormal && store.isValidPath(selected)) {
                store.addTempRoot(selected);
            } else {
                /* The record names a candidate; it is not valid until the
                   ordinary substitution has fetched and verified it. */
                store.addTempRoot(selected);
                allRealised = false;
            }
        } else {
            store.addTempRoot(output.second.path);
            allRealised = false;
        }
        drv.env[output.first] = output.second.path;
    }
    /* A check builds at the logical token, never at the selected final path.
       A normal build keeps the selected candidate through substitution. */
    if (addressingOf(drv) == Addressing::content && mode != bmNormal)
        for (auto & output : drv.outputs) {
            if (!output.second.hash.empty()) continue;
            output.second.path = tokenPath(output.first,
                storePathToName(original.outputs.at(output.first).path));
            drv.env[output.first] = output.second.path;
        }
    return {drv, "", mode == bmNormal && allRealised};
}

GoonixGoalState prepareGoonixGoal(LocalStore & store, const Path & path,
    const Path & originalPath, const Derivation & input,
    const Derivation & original, BuildMode mode, unsigned int repeat)
{
    GoonixGoalState state;
    state.drv = input;
    state.originalPath = originalPath.empty() ? path : originalPath;
    if (!goonixAddressed(input)) return state;
    const Derivation & originalDrv = original.outputs.empty() ? input : original;
    if (!resolvedDerivation(input)) {
        if (mode == bmNormal) {
            for (auto & output : originalDrv.outputs) {
                Path chosen = store.chosenGoonixOutput(state.originalPath,
                                                       output.first);
                if (!chosen.empty() && !store.isValidPath(chosen)) {
                    state.action = GoonixGoalAction::substituteOutputs;
                    state.missingPaths.insert(chosen);
                    return state;
                }
            }
        }
        state.action = GoonixGoalAction::substituteInputs;
        return state;
    }
    auto prepared = prepareResolvedBuild(store, state.originalPath, originalDrv,
        input, mode);
    state.drv = prepared.drv;
    if (prepared.allRealised) {
        state.action = GoonixGoalAction::done;
        return state;
    }
    goonixInputPaths(store, state.drv, state.inputPaths, state.allPaths);
    state.missingPaths = outputPaths(state.drv);
    if (mode == bmNormal)
        for (auto & output : state.drv.outputs)
            if (!store.isValidPath(output.second.path))
                state.missingPaths.insert(output.second.path);
    auto kind = goonixBuildKind(state.drv, repeat);
    state.fixedOutput = kind.fixedOutput;
    state.rounds = kind.rounds;
    state.action = GoonixGoalAction::build;
    if (mode == bmNormal)
        for (auto & output : state.drv.outputs)
            if (!store.isValidPath(output.second.path) &&
                store.chosenGoonixOutput(state.originalPath, output.first) ==
                output.second.path)
                state.action = GoonixGoalAction::substituteOutputs;
    return state;
}

GoonixResolvedState resolveGoonixBuild(LocalStore & store,
    const Path & originalPath, const Derivation & original)
{
    auto resolved = resolveDerivation(store, originalPath, original);
    auto path = writeResolvedDerivation(store, originalPath, resolved);
    store.addTempRoot(path);
    selectGoonixOutputs(store, originalPath, resolved);
    return {resolved, path, false};
}

bool goonixBuildAlreadyRealised(LocalStore & store, const Path & originalPath,
    const Derivation & drv)
{
    if (!resolvedDerivation(drv) || addressingOf(drv) == Addressing::input)
        return false;
    const string resolvedHash = printHash(hashString(htSHA256, unparseDerivation(drv)));
    for (auto & output : drv.outputs) {
        Path selected = store.selectGoonixOutput(originalPath,
            output.first, resolvedHash, "", false);
        if (selected.empty()) return false;
        store.addTempRoot(selected);
    }
    return true;
}

void selectGoonixOutputs(LocalStore & store, const Path & originalPath,
    Derivation & drv)
{
    const string resolvedHash = printHash(hashString(htSHA256, unparseDerivation(drv)));
    for (auto & output : drv.outputs) {
        Path selected = store.selectGoonixOutput(originalPath,
            output.first, resolvedHash, "", false);
        if (!selected.empty()) drv.outputs[output.first].path = selected;
    }
}

void goonixInputPaths(StoreAPI & store, const Derivation & drv,
    PathSet & inputPaths, PathSet & allPaths)
{
    for (auto & source : drv.inputSrcs)
        computeFSClosure(store, source, inputPaths);
    if (isInStore(drv.builder))
        computeFSClosure(store, toStorePath(drv.builder), inputPaths);
    allPaths.insert(inputPaths.begin(), inputPaths.end());
    for (auto & output : drv.outputs) allPaths.insert(output.second.path);
}

void removeGoonixEnvironment(StringPairs & environment)
{
    for (auto it = environment.begin(); it != environment.end(); ) {
        if (it->first.starts_with("goonix") ||
            it->first == "__files" || it->first.starts_with("__file:"))
            it = environment.erase(it);
        else ++it;
    }
}

void materialiseGoonixFiles(const Derivation & drv, Strings & arguments,
    const Path & hostDirectory, const Path & sandboxDirectory)
{
    auto embedded = drv.env.find("__files");
    if (embedded == drv.env.end()) return;
    for (auto & name : tokenizeString<Strings>(embedded->second)) {
        if (name.empty() || name[0] == '/' || name.find("\\") != string::npos)
            throw BuildError(std::format("invalid embedded builder file `{}'", name));
        std::istringstream components(name);
        string component;
        while (std::getline(components, component, '/'))
            if (component.empty() || component == "." || component == "..")
                throw BuildError(std::format("invalid embedded builder file `{}'", name));
        auto value = drv.env.find("__file:" + name);
        if (value == drv.env.end())
            throw BuildError(std::format("missing embedded builder file `{}'", name));
        Path file = hostDirectory + "/" + name;
        Path sandboxFile = sandboxDirectory + "/" + name;
        for (auto & arg : arguments)
            if (arg == "$NIX_BUILD_TOP/" + name) arg = sandboxFile;
        createDirs(dirOf(file));
        writeFile(file, value->second);
    }
}

void checkGoonixReferences(StoreAPI & store, const Derivation & drv,
    const Path & path, const Path & token,
    const std::map<Path, Path> & finalOutputs, const PathSet & references)
{
    auto checkRefs = [&](const string & attrName, bool allowed, bool recursive) {
        if (drv.env.find(attrName) == drv.env.end()) return;
        PathSet spec;
        for (auto & item : tokenizeString<Paths>(drv.env.at(attrName))) {
            if (isStorePath(item)) spec.insert(item);
            else {
                auto output = drv.outputs.find(item);
                if (output == drv.outputs.end())
                    throw BuildError(std::format(
                        "derivation contains an invalid reference specifier `{}'", item));
                if (output->second.path == token) spec.insert(path);
                else {
                    auto final = finalOutputs.find(output->second.path);
                    spec.insert(final == finalOutputs.end()
                        ? output->second.path : final->second);
                }
            }
        }
        PathSet used;
        if (recursive) {
            for (auto & reference : references)
                if (path != reference && token != reference)
                    computeFSClosure(store, reference, used);
        } else used = references;
        for (auto & reference : used) {
            if (allowed) {
                if (!spec.count(reference))
                    throw BuildError(std::format(
                        "output (`{}') is not allowed to refer to path `{}'", path, reference));
            } else if (spec.count(reference))
                throw BuildError(std::format(
                    "output (`{}') is not allowed to refer to path `{}'", path, reference));
        }
    };
    checkRefs("allowedReferences", true, false);
    checkRefs("allowedRequisites", true, true);
    checkRefs("disallowedReferences", false, false);
    checkRefs("disallowedRequisites", false, true);
}

GoonixOutputResult finaliseGoonixOutputs(LocalStore & store,
    Derivation & drv, const Derivation & original, const Path & resolvedPath,
    const Path & originalPath, const PathSet & allPaths,
    const PathSet & missingPaths, bool useChroot, const Path & chrootRoot,
    BuildMode mode, uid_t uid, gid_t gid, InodesSeen & inodesSeen,
    const std::function<void()> & cleanup)
{
    GoonixOutputContext context {store, drv, original, resolvedPath, originalPath,
        allPaths, missingPaths, useChroot, chrootRoot, mode, uid, gid,
        [&](const Path & path) { canonicalisePathMetaData(path,
            uid == (uid_t) -1 ? -1 : uid, inodesSeen); }, cleanup};
    GoonixOutputResult result;
    if (addressingOf(drv) != Addressing::content) return result;
    for (auto & output : drv.outputs)
        if (!output.second.hash.empty() &&
            (drv.outputs.size() != 1 || output.first != "out"))
            throw BuildError(
                "a content-addressed derivation with a fixed output must have only `out'");

    if (resolvedDerivation(drv))
        for (auto & output : drv.outputs) {
            const Path & path = output.second.path;
            if (context.missingPaths.find(path) == context.missingPaths.end() ||
                !output.second.hash.empty()) continue;
            const Path actualPath = context.useChroot ? context.chrootRoot + path : path;
            if (!pathExists(actualPath))
                throw BuildError(std::format(
                    "builder for `{}' failed to produce output path `{}'",
                    context.resolvedPath, path));
        }

    auto order = resolvedDerivation(drv)
        ? contentOutputOrder(drv, [&] {
            PathSet paths = context.allPaths;
            for (auto & output : drv.outputs) paths.insert(output.second.path);
            return paths;
          }(), context.useChroot ? context.chrootRoot : "")
        : std::vector<std::pair<string, Path>>{};
    if (order.empty())
        for (auto & output : drv.outputs) order.push_back({output.first, output.second.path});

    for (auto & ordered : order) {
        auto & i = *drv.outputs.find(ordered.first);
        Path path = i.second.path;
        if (context.missingPaths.find(path) == context.missingPaths.end()) continue;
        Path actualPath = context.useChroot ? context.chrootRoot + path : path;
        if (!resolvedDerivation(drv) || !i.second.hash.empty()) continue;

        context.canonicalise(actualPath);
        Path finalisationPath = actualPath;
        if (context.useChroot) {
            Path staged = settings.nixStore + "/.goonix-tmp-" +
                std::to_string(getpid()) + "-" + i.first;
            if (pathExists(staged)) deletePath(staged);
            if (rename(actualPath.c_str(), staged.c_str()) != 0)
                copyFileRecursively(actualPath, staged, true);
            finalisationPath = staged;
        }
        StringSet deepTokens;
        for (auto & output : context.original.outputs)
            deepTokens.insert(selfToken(output.first));
        checkDeepOutput(finalisationPath, deepTokens, context.uid, context.gid,
            context.cleanup);
        if (context.mode == bmCheck) {
            ValidPathInfo checkInfo;
            Path checkFinal = finaliseContentOutput(context.store, path,
                i.first, storePathToName(path), context.allPaths, checkInfo.references,
                checkInfo.hash, checkInfo.narSize, result.finalOutputs,
                finalisationPath);
            result.finalOutputs[path] = checkFinal;
            checkInfo.path = checkFinal;
            checkInfo.deriver = context.resolvedPath;
            if (!context.store.isValidPath(checkFinal))
                context.store.registerValidPath(checkInfo);
            context.store.recordBuild(context.resolvedPath, i.first, checkFinal,
                "local-check", false);
            Path chosen = context.store.chosenOutput(context.originalPath, i.first);
            if (checkFinal != chosen)
                printMsg(lvlError, std::format(
                    "goonix: `{0}' is not reproducible: output `{1}' rebuilt to `{2}', choice is `{3}' (second record stored)",
                    context.originalPath, i.first, checkFinal, chosen));
            result.check = true;
            continue;
        }
        ValidPathInfo info;
        bool created = false;
        info.path = path;
        Path final = finaliseContentOutput(context.store, path,
            i.first, storePathToName(path), context.allPaths, info.references,
            info.hash, info.narSize, result.finalOutputs, finalisationPath,
            &created);
        result.finalOutputs[path] = final;
        if (created) result.stagedOutputs.insert(final);
        context.store.addTempRoot(final);
        info.path = final;
        info.deriver = context.resolvedPath;
        checkGoonixReferences(context.store, drv, final, path,
            result.finalOutputs, info.references);
        result.infos.push_back(info);
        result.facts.push_back({i.first, final});
    }
    return result;
}

void discardGoonixOutputs(StoreAPI & store, const GoonixOutputResult & result)
{
    for (auto & output : result.finalOutputs)
        if (result.stagedOutputs.count(output.second) &&
            !store.isValidPath(output.second) && pathExists(output.second))
            deletePath(output.second);
}

void recordGoonixOutput(LocalStore & store, const Path & originalPath,
    const Path & resolvedPath, const string & output, const Path & path,
    const string & origin)
{
    store.recordBuild(resolvedPath, output, path, origin, false);
    store.chooseOutput(originalPath, output, path);
}

void recordGoonixFacts(LocalStore & store, const Path & originalPath,
    const Path & resolvedPath,
    const std::vector<std::pair<string, Path>> & facts)
{
    for (auto & fact : facts)
        recordGoonixOutput(store, originalPath, resolvedPath,
            fact.first, fact.second, "local");
}

}
