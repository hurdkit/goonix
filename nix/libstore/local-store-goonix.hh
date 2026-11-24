// goonix: LocalStore's content-addressing API; included inside the class.
GoalPtr makeGoonixGraphGoal(Worker & worker, const Path & path);
void goonixGraphReply(const Path & path, const Strings & fields,
    unsigned int hints);

Path realisedOutputPath(const Path & drvPath, const Derivation & drv,
    const string & output);
Path resolvedDerivationPath(const Path & originalPath,
    const Derivation & resolved);
void recordBuild(const Path & resolvedPath, const string & output,
    const Path & path, const string & origin, bool relocationChecked);
void recordGoonixBuild(const Path & resolvedPath, const string & output,
    const Path & path, const string & resolvedHash, const string & origin,
    bool relocationChecked, const string & signature);
void recordGoonixBuildWithResolved(const Path & resolvedPath,
    const string & output, const Path & path, const string & resolvedHash,
    const string & origin, bool relocationChecked, const string & signature,
    const string & resolvedBytes);
std::vector<BuildRecord> queryGoonixBuildRecords(const string & hash,
    const string & output);
std::vector<BuildRecord> queryGoonixRecordsByPath(const Path & path);
std::vector<BuildRecord> queryGoonixRecordsByResolved(const Path & resolved);
std::pair<std::vector<BuildRecord>, Strings>
    queryGoonixBuildGraph(const Path & unresolved);
std::pair<std::vector<BuildRecord>, Strings>
    importGoonixBuildGraph(const Path & unresolved,
        const std::vector<BuildRecord> & offered,
        const OutputChoices & serverChoices);
std::vector<RecordConflict> queryGoonixConflicts(const string & hash,
    const string & output);
PathSet goonixDerivationsForPath(const Path & path);
PathSet goonixOriginalsForPath(const Path & path);
PathSet goonixChosenPaths(const Path & unresolved);
Path selectGoonixOutput(const Path & unresolved, const string & output,
    const string & resolvedHash, const Path & preferred, bool adopt);
void chooseGoonixOutput(const Path & unresolved, const string & output,
    const Path & realised);
Path chosenGoonixOutput(const Path & unresolved, const string & output);
void chooseOutput(const Path & unresolved, const string & output,
    const Path & realised);
Path chosenOutput(const Path & unresolved, const string & output);
Path chosenOutputForCurrentGraph(const Path & unresolved, const string & output);
OutputChoices choices(const Path & unresolved);
string signBuildRecord(const string & payload);
void initialiseGoonixRecords();
Path addResolvedDerivation(const string & name, const string & contents,
    const PathSet & references);
Path addTextToStoreNoDerivationOutputs(const string & name,
    const string & contents, const PathSet & references);
