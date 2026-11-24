// goonix: build-record storage, selection policy and conflict tracking.
#include "records.hh"
#include "serialise.hh"
#include "util.hh"
#include <sqlite3.h>
#include <format>

namespace nix {

static void execute(sqlite3 * db, const string & sql)
{
    if (sqlite3_exec(db, sql.c_str(), 0, 0, 0) != SQLITE_OK)
        throwSQLiteError(db, "updating goonix build records");
}

BuildRecords::BuildRecords(sqlite3 * db) : db(db) { }

SQLiteTxn BuildRecords::transaction() { return SQLiteTxn(db); }

void BuildRecords::initialise()
{
    execute(db, R"sql(
create table if not exists GoonixBuildRecords (
    id integer primary key autoincrement not null,
    resolvedHash text not null,
    resolvedDerivation text not null,
    output text not null,
    path text not null,
    origin text not null,
    relocationChecked integer not null,
    signature text not null,
    unique(resolvedHash, output, path, origin, signature));
create index if not exists GoonixRecordLookup
    on GoonixBuildRecords(resolvedHash, output);
create index if not exists GoonixRecordByPath
    on GoonixBuildRecords(path);
create index if not exists GoonixRecordByResolved
    on GoonixBuildRecords(resolvedDerivation);
create table if not exists GoonixChoices (
    derivation text not null,
    output text not null,
    path text not null,
    primary key(derivation, output));
create table if not exists GoonixConflicts (
    id integer primary key autoincrement not null,
    resolvedHash text not null,
    output text not null,
    pathA text not null,
    pathB text not null,
    origin text not null,
    unique(resolvedHash, output, pathA, pathB));
create index if not exists GoonixConflictLookup
    on GoonixConflicts(resolvedHash, output);
)sql");
}

string canonicalBuildRecordPayload(const BuildRecord & record)
{
    StringSink payload;
    const string domain("goonix-record-v1\0", 17);
    payload((const unsigned char *) domain.data(), domain.size());
    writeLongLong(1, payload);
    for (auto & field : {record.resolvedHash, record.resolvedDerivation,
             record.output, record.path, record.origin}) {
        writeLongLong(field.size(), payload);
        payload((const unsigned char *) field.data(), field.size());
    }
    writeLongLong(record.relocationChecked ? 1 : 0, payload);
    return std::move(payload.s);
}

/* Record a disagreement between two results for one resolved derivation.
   Facts are permanent, so a second, different result is stored and the
   pair is surfaced as a reproducibility conflict (plan 3.3, 10). */
static void noteConflict(sqlite3 * db, const BuildRecord & record)
{
    SQLiteStmt stmt;
    stmt.create(db, "select distinct path from GoonixBuildRecords "
        "where resolvedHash = ? and output = ? and path != ?;");
    auto use = stmt.use();
    use(record.resolvedHash)(record.output)(record.path);
    std::vector<Path> others;
    while (use.next()) others.push_back(use.getStr(0));
    for (auto & other : others) {
        SQLiteStmt ins;
        ins.create(db, "insert or ignore into GoonixConflicts "
            "(resolvedHash, output, pathA, pathB, origin) "
            "values (?, ?, ?, ?, ?);");
        /* Order the pair so the same disagreement is stored once. */
        Path a = other < record.path ? other : record.path;
        Path b = other < record.path ? record.path : other;
        ins.use()(record.resolvedHash)(record.output)(a)(b)(record.origin).exec();
    }
}

void BuildRecords::add(const BuildRecord & record)
{
    if (record.resolvedHash.size() != 64 || record.output.empty() ||
        record.origin.empty() || record.signature.empty())
        throw Error("invalid or unsigned goonix build record");
    noteConflict(db, record);
    SQLiteStmt stmt;
    stmt.create(db, "insert or ignore into GoonixBuildRecords "
        "(resolvedHash, resolvedDerivation, output, path, origin, "
        "relocationChecked, signature) values (?, ?, ?, ?, ?, ?, ?);");
    stmt.use()(record.resolvedHash)(record.resolvedDerivation)
        (record.output)(record.path)(record.origin)
        (record.relocationChecked ? 1 : 0)(record.signature).exec();
}

static BuildRecord readRecord(SQLiteStmt::Use & use)
{
    return {use.getStr(0), use.getStr(1), use.getStr(2),
        use.getStr(3), use.getStr(4), use.getInt(5) != 0, use.getStr(6)};
}

static const char * recordColumns =
    "resolvedHash, resolvedDerivation, output, path, "
    "origin, relocationChecked, signature";

std::vector<BuildRecord> BuildRecords::query(const string & resolvedHash,
    const string & output)
{
    SQLiteStmt stmt;
    stmt.create(db, std::format("select {} from GoonixBuildRecords "
        "where resolvedHash = ? and (? = '' or output = ?) order by id;",
        recordColumns));
    auto use = stmt.use();
    use(resolvedHash)(output)(output);
    std::vector<BuildRecord> result;
    while (use.next()) result.push_back(readRecord(use));
    return result;
}

std::vector<BuildRecord> BuildRecords::queryByPath(const Path & path)
{
    SQLiteStmt stmt;
    stmt.create(db, std::format("select {} from GoonixBuildRecords "
        "where path = ? order by id;", recordColumns));
    auto use = stmt.use();
    use(path);
    std::vector<BuildRecord> result;
    while (use.next()) result.push_back(readRecord(use));
    return result;
}

std::vector<BuildRecord> BuildRecords::queryByResolvedDerivation(const Path & resolved)
{
    SQLiteStmt stmt;
    stmt.create(db, std::format("select {} from GoonixBuildRecords "
        "where resolvedDerivation = ? order by id;", recordColumns));
    auto use = stmt.use();
    use(resolved);
    std::vector<BuildRecord> result;
    while (use.next()) result.push_back(readRecord(use));
    return result;
}

PathSet BuildRecords::derivationsForPath(const Path & path)
{
    SQLiteStmt stmt;
    stmt.create(db, "select distinct resolvedDerivation from GoonixBuildRecords "
        "where path = ?;");
    auto use = stmt.use();
    use(path);
    PathSet result;
    while (use.next()) result.insert(use.getStr(0));
    return result;
}

PathSet BuildRecords::originalsForPath(const Path & path)
{
    SQLiteStmt stmt;
    stmt.create(db, "select distinct derivation from GoonixChoices "
        "where path = ?;");
    auto use = stmt.use();
    use(path);
    PathSet result;
    while (use.next()) result.insert(use.getStr(0));
    return result;
}

PathSet BuildRecords::chosenPaths(const Path & unresolved)
{
    SQLiteStmt stmt;
    stmt.create(db, "select path from GoonixChoices where derivation = ?;");
    auto use = stmt.use();
    use(unresolved);
    PathSet result;
    while (use.next()) result.insert(use.getStr(0));
    return result;
}

std::vector<RecordConflict> BuildRecords::conflicts(const string & resolvedHash,
    const string & output)
{
    SQLiteStmt stmt;
    stmt.create(db, "select resolvedHash, output, pathA, pathB, origin "
        "from GoonixConflicts where resolvedHash = ? and (? = '' or output = ?) "
        "order by id;");
    auto use = stmt.use();
    use(resolvedHash)(output)(output);
    std::vector<RecordConflict> result;
    while (use.next())
        result.push_back({use.getStr(0), use.getStr(1), use.getStr(2),
            use.getStr(3), use.getStr(4)});
    return result;
}

Strings goonixRecordFields(const std::vector<BuildRecord> & records,
    bool includeHash)
{
    Strings fields;
    for (auto & record : records) {
        if (includeHash) fields.push_back(record.resolvedHash);
        fields.push_back(record.resolvedDerivation);
        fields.push_back(record.output);
        fields.push_back(record.path);
        fields.push_back(record.origin);
        fields.push_back(record.relocationChecked ? "1" : "0");
        fields.push_back(record.signature);
    }
    return fields;
}

void BuildRecords::choose(const Path & unresolved, const string & output,
    const Path & realised)
{
    SQLiteStmt stmt;
    stmt.create(db, "insert or ignore into GoonixChoices "
        "(derivation, output, path) values (?, ?, ?);");
    stmt.use()(unresolved)(output)(realised).exec();
}

void BuildRecords::rechoose(const Path & unresolved, const string & output,
    const Path & realised)
{
    SQLiteStmt stmt;
    stmt.create(db, "insert or replace into GoonixChoices "
        "(derivation, output, path) values (?, ?, ?);");
    stmt.use()(unresolved)(output)(realised).exec();
}

Path BuildRecords::choice(const Path & unresolved, const string & output)
{
    SQLiteStmt stmt;
    stmt.create(db, "select path from GoonixChoices where derivation = ? and output = ?;");
    auto use = stmt.use();
    use(unresolved)(output);
    return use.next() ? use.getStr(0) : "";
}

OutputChoices BuildRecords::choices(const Path & unresolved)
{
    SQLiteStmt stmt;
    stmt.create(db, "select output, path from GoonixChoices where derivation = ?;");
    auto use = stmt.use();
    use(unresolved);
    OutputChoices result;
    while (use.next()) result[{unresolved, use.getStr(0)}] = use.getStr(1);
    return result;
}

void BuildRecords::drop(const Path & unresolved, const string & output)
{
    SQLiteStmt stmt;
    stmt.create(db, "delete from GoonixChoices where derivation = ? and output = ?;");
    stmt.use()(unresolved)(output).exec();
}

}
