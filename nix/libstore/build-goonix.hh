// goonix: private DerivationGoal state and CA-only member hooks.
Path originalDrvPath;
Derivation originalDrv;
bool goonixGraphRequested = false;
bool goonixGraphSettled = false;
bool goonixSubstitutionRequested = false;
void addInputWaitees();
bool goonixHaveDerivation();
bool goonixRealiseInputsFirst();
bool goonixResolveInputs();
void goonixRegisterOutputs(InodesSeen & inodesSeen, ValidPathInfos & infos);
void goonixRecordResolvedOutput(const string & output, const Path & path);
void goonixDiscardOutputs();
bool goonixSelectedOutputsSubstituted();
void goonixPrepareLocalBuild();
void goonixRegisterValidPaths(ValidPathInfos & infos);
bool goonixRecheckRealised();
GoonixOutputResult goonixOutputResult;
