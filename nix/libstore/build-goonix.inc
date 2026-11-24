GoalPtr Worker::makeGoonixGraphGoal(const Path & path)
{
    GoalPtr goal = goonixGraphGoals[path].lock();
    if (!goal) {
        goal = GoalPtr(new GoonixGraphGoal(path, *this));
        goonixGraphGoals[path] = goal;
        wakeUp(goal);
    }
    return goal;
}

GoalPtr LocalStore::makeGoonixGraphGoal(Worker & worker, const Path & path)
{
    return worker.makeGoonixGraphGoal(path);
}

void Worker::goonixSetChildDeadline(pid_t pid, time_t deadline)
{
    children[pid].deadline = deadline;
}

// goonix: member hooks for the CA scheduler; no upstream function bodies.
bool DerivationGoal::goonixHaveDerivation()
{
    if (goonixGraphRequested) goonixGraphSettled = true;
    if (worker.isTopGoal(shared_from_this()) && !goonixGraphRequested &&
        !resolvedDerivation(drv) &&
        goonixAddressed(drv) && buildMode == bmNormal && settings.useSubstitutes) {
        bool missing = false;
        try {
            for (auto & output : drv.outputs)
                if (wantedOutputs.empty() || wantedOutputs.count(output.first)) {
                    Path path = worker.store.realisedOutputPath(drvPath, drv,
                                                               output.first);
                    if (path.empty() || !worker.store.isValidPath(path))
                        missing = true;
                }
        } catch (...) { missing = true; }
        if (missing) {
            goonixGraphRequested = true;
            GoalPtr graph = worker.store.makeGoonixGraphGoal(worker, drvPath);
            if (graph->getExitCode() == Goal::ecBusy) {
                addWaitee(graph);
                state = &DerivationGoal::haveDerivation;
                return true;
            }
            /* An already completed optional goal has no waitee to wake us;
               continue the ordinary CA path immediately. */
        }
        /* Keep the original unresolved file, but reread its choices below. */
        originalDrv = drv;
    }
    if (!goonixAddressed(drv)) {
        checkInputAddressedPolicy(worker.store, drv);
        return false;
    }
    auto prepared = prepareGoonixGoal(worker.store, drvPath, originalDrvPath,
        drv, originalDrv, buildMode, settings.get("build-repeat", 0));
    originalDrvPath = prepared.originalPath;
    if (originalDrv.outputs.empty()) originalDrv = drv;
    drv = prepared.drv;
    if (prepared.action == GoonixGoalAction::done) {
        done(BuildResult::AlreadyValid);
        return true;
    }
    inputPaths = prepared.inputPaths;
    allPaths = prepared.allPaths;
    missingPaths = prepared.missingPaths;
    fixedOutput = prepared.fixedOutput;
    nrRounds = prepared.rounds;
    if (prepared.action == GoonixGoalAction::substituteOutputs) {
        for (auto & output : originalDrv.outputs) {
            Path chosen = worker.store.chosenOutputForCurrentGraph(originalDrvPath,
                                                                  output.first);
            if (!chosen.empty() && !worker.store.isValidPath(chosen)) {
                addWaitee(worker.makeSubstitutionGoal(chosen));
                goonixSubstitutionRequested = true;
                drv.outputs[output.first].path = chosen;
                drv.env[output.first] = chosen;
            }
        }
        state = &DerivationGoal::outputsSubstituted;
        if (waitees.empty()) worker.wakeUp(shared_from_this());
        return true;
    }
    state = prepared.action == GoonixGoalAction::build
        ? &DerivationGoal::tryToBuild : &DerivationGoal::outputsSubstituted;
    worker.wakeUp(shared_from_this());
    return true;
}

bool DerivationGoal::goonixRealiseInputsFirst()
{
    if (!goonixAddressed(drv) || resolvedDerivation(drv)) return false;
    wantedOutputs = PathSet();
    addInputWaitees();
    if (waitees.empty()) inputsRealised();
    else state = &DerivationGoal::inputsRealised;
    return true;
}

bool DerivationGoal::goonixResolveInputs()
{
    if (!goonixAddressed(drv) || resolvedDerivation(drv)) return false;
    auto resolved = resolveGoonixBuild(worker.store, originalDrvPath, originalDrv);
    drv = resolved.drv;
    drvPath = resolved.resolvedPath;
    haveDerivation();
    if (state == &DerivationGoal::tryToBuild) worker.wakeUp(shared_from_this());
    return true;
}

void DerivationGoal::addInputWaitees()
{
    for (auto & input : drv.inputDrvs)
        addWaitee(worker.makeDerivationGoal(input.first, input.second,
            buildMode == bmRepair ? bmRepair : bmNormal));
    for (auto & source : drv.inputSrcs)
        addWaitee(worker.makeSubstitutionGoal(source));
}

void DerivationGoal::goonixRegisterOutputs(InodesSeen & inodesSeen,
    ValidPathInfos & infos)
{
    goonixOutputResult = finaliseGoonixOutputs(worker.store, drv, originalDrv,
        drvPath, originalDrvPath, allPaths, missingPaths, useChroot, chrootRootDir,
        buildMode, buildUser.enabled() ? buildUser.getUID() : (uid_t) -1,
        buildUser.enabled() ? buildUser.getGID() : (gid_t) -1, inodesSeen,
        [&] { if (buildUser.enabled()) buildUser.kill(); });
    infos.splice(infos.end(), goonixOutputResult.infos);
}

void DerivationGoal::goonixRecordResolvedOutput(const string & output,
    const Path & path)
{
    if (resolvedDerivation(drv))
        recordGoonixOutput(worker.store, originalDrvPath, drvPath,
            output, path, "local");
}

void DerivationGoal::goonixDiscardOutputs()
{
    discardGoonixOutputs(worker.store, goonixOutputResult);
}

void DerivationGoal::goonixRegisterValidPaths(ValidPathInfos & infos)
{
    try {
        worker.store.registerValidPaths(infos);
        if (resolvedDerivation(drv))
            recordGoonixFacts(worker.store, originalDrvPath, drvPath,
                goonixOutputResult.facts);
    } catch (...) {
        goonixDiscardOutputs();
        throw;
    }
}

bool DerivationGoal::goonixRecheckRealised()
{
    if (buildMode != bmNormal ||
        !goonixBuildAlreadyRealised(worker.store, originalDrvPath, drv)) return false;
    outputLocks.setDeletion(true);
    outputLocks.unlock();
    done(BuildResult::AlreadyValid);
    return true;
}

bool DerivationGoal::goonixSelectedOutputsSubstituted()
{
    if (!goonixSubstitutionRequested || !goonixAddressed(drv) || buildMode != bmNormal)
        return false;
    for (auto & output : originalDrv.outputs) {
        Path chosen = worker.store.chosenOutputForCurrentGraph(originalDrvPath, output.first);
        if (chosen.empty() || !worker.store.isValidPath(chosen)) {
            needRestart = true;
            goonixGraphRequested = true;
            goonixGraphSettled = true;
            return false;
        }
    }
    done(BuildResult::Substituted);
    return true;
}

void DerivationGoal::goonixPrepareLocalBuild()
{
    if (addressingOf(drv) != Addressing::content || buildMode != bmNormal)
        return;
    for (auto & output : drv.outputs) {
        if (!output.second.hash.empty() || worker.store.isValidPath(output.second.path))
            continue;
        output.second.path = tokenPath(output.first,
            storePathToName(originalDrv.outputs.at(output.first).path));
        drv.env[output.first] = output.second.path;
    }
}

GoonixGraphGoal::GoonixGraphGoal(const Path & path, Worker & worker)
    : Goal(worker), drvPath(path), state(&GoonixGraphGoal::start)
{
    name = std::format("goonix graph query for `{}'", path);
    caches = settings.get("substitute-urls", Strings());
    next = caches.begin();
}

GoonixGraphGoal::~GoonixGraphGoal()
{
    if (agent) worker.childTerminated(agent->pid);
}

void GoonixGraphGoal::work()
{
    if (waiting) return;
    (this->*state)();
}

void GoonixGraphGoal::finishWithoutFailure(const string & reason)
{
    printMsg(lvlInfo, std::format("goonix: graph sharing for `{}': {}",
                                 drvPath, reason));
    waiting = false;
    if (agent) {
        pid_t pid = agent->pid;
        agent.reset();
        worker.childTerminated(pid);
    }
    amDone(ecSuccess);
}

void GoonixGraphGoal::timedOut()
{
    printMsg(lvlError, std::format("{} reached its graph cache deadline", getName()));
    retry("cache deadline expired");
}

void GoonixGraphGoal::retry(const string & reason)
{
    if (agent) {
        pid_t pid = agent->pid;
        agent.reset();
        worker.childTerminated(pid);
    }
    input.clear();
    oversized = false;
    eof = false;
    printMsg(reason == "cache has no graph" ? lvlInfo : lvlError,
             std::format("goonix: graph cache for `{}': {}", drvPath, reason));
    state = &GoonixGraphGoal::start;
    waiting = false;
    worker.wakeUp(shared_from_this());
}

void GoonixGraphGoal::start()
{
    if (next == caches.end()) {
        finishWithoutFailure("no usable cache answer; building locally if needed");
        return;
    }
    string cache = *next++;
    try {
        const Strings args = { "substitute", "--goonix-graph" };
        const std::map<string, string> env = {{ "_NIX_OPTIONS", settings.pack() }};
        agent = std::make_shared<Agent>(settings.guixProgram, args, env);
        writeLine(agent->toAgent.writeSide, "records " + drvPath + " " + cache);
        set<int> fds{agent->fromAgent.readSide, agent->builderOut.readSide};
        worker.childStarted(shared_from_this(), agent->pid, fds, false, false);
        if (settings.goonixGraphTimeout)
            worker.goonixSetChildDeadline(agent->pid,
                                         time(0) + settings.goonixGraphTimeout);
        state = &GoonixGraphGoal::finish;
        waiting = true;
    } catch (std::exception & e) {
        retry("helper unavailable");
    }
}

void GoonixGraphGoal::handleChildOutput(int fd, const string & data)
{
    if (fd == agent->fromAgent.readSide) {
        writeToStderr("goonix graph helper: " + data);
        return;
    }
    if (fd != agent->builderOut.readSide) return;
    constexpr size_t maximum = 128 * 1024 * 1024;
    if (oversized) return;
    size_t remaining = maximum - input.size();
    input.append(data, 0, std::min(data.size(), remaining));
    if (data.size() > remaining) {
        input.clear();
        oversized = true;
        waiting = false;
        worker.wakeUp(shared_from_this());
        return;
    }
    if (input.find('\n') != string::npos) {
        waiting = false;
        worker.wakeUp(shared_from_this());
    }
}

void GoonixGraphGoal::handleEOF(int fd)
{
    /* A dead helper may close stderr before fd 4.  Neither pipe can provide
       more of a response after either side has gone away. */
    eof = true;
    waiting = false;
    worker.wakeUp(shared_from_this());
}

void GoonixGraphGoal::finish()
{
    if (oversized) {
        retry("answer exceeded its size limit");
        return;
    }
    Strings fields;
    unsigned int nrHints = 0;
    string error;
    bool complete = parseGoonixGraphResponse(input, eof, 128 * 1024 * 1024,
                                             fields, nrHints, error);
    if (!error.empty()) {
        retry(error);
        return;
    }
    if (!complete) {
        waiting = true;
        return;
    }
    if (fields.empty() && nrHints == 0) {
        retry("cache has no graph");
        return;
    }
    try {
        worker.store.goonixGraphReply(drvPath, fields, nrHints);
        finishWithoutFailure("answer imported");
    } catch (std::exception & e) {
        retry("answer refused: " + string(e.what()));
    }
}

void LocalStore::goonixGraphReply(const Path & unresolved,
    const Strings & fields, unsigned int nrHints)
{
    auto decode = [](const string & encoded) {
        if (encoded.size() % 2) throw Error("odd graph field encoding");
        string result;
        auto digit = [](char c) -> unsigned int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            throw Error("invalid graph field encoding");
        };
        for (size_t i = 0; i < encoded.size(); i += 2)
            result.push_back((digit(encoded[i]) << 4) | digit(encoded[i + 1]));
        return result;
    };
    if (fields.size() < nrHints * 3 || (fields.size() - nrHints * 3) % 7)
        throw Error("graph reply has inconsistent field counts");
    std::vector<string> decoded;
    for (auto & field : fields) decoded.push_back(decode(field));
    size_t nrRecords = (fields.size() - nrHints * 3) / 7;
    std::vector<BuildRecord> records;
    size_t pos = 0;
    for (size_t i = 0; i < nrRecords; i++) {
        BuildRecord record;
        record.resolvedHash = decoded[pos++];
        record.resolvedDerivation = decoded[pos++];
        record.output = decoded[pos++];
        record.path = decoded[pos++];
        record.origin = decoded[pos++];
        record.relocationChecked = decoded[pos++] == "1";
        record.signature = decoded[pos++];
        records.push_back(record);
    }
    OutputChoices hints;
    for (unsigned int i = 0; i < nrHints; i++) {
        Path original = decoded[pos++];
        string output = decoded[pos++];
        Path path = decoded[pos++];
        hints[std::make_pair(original, output)] = path;
    }
    importGoonixBuildGraph(unresolved, records, hints);
}
