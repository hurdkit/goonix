// goonix: build-record storage, selection policy and conflict tracking.
#include "records.hh"
#include "ca-record-signature.hh"
#include "ca.hh"
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

    /* Choose one representation at the storage boundary.  A legacy raw
       advanced S-expression and its base64 form are the same signature, not
       two facts.  Do this at open so old raw/encoded twins also converge;
       repeating it is a no-op once every row is canonical. */
    auto txn = transaction();
    SQLiteStmt rows;
    rows.create(db, "select id, signature from GoonixBuildRecords "
        "where substr(signature, 1, 1) = '(' order by id;");
    std::vector<std::pair<int64_t, string>> legacy;
    {
        auto use = rows.use();
        while (use.next()) {
            auto bytes = (const char *) sqlite3_column_blob(rows, 1);
            int size = sqlite3_column_bytes(rows, 1);
            if (!bytes) throw Error("null legacy goonix record signature");
            legacy.emplace_back(use.getInt(0), string(bytes, size));
        }
    }
    for (auto & [id, raw] : legacy) {
        string signature = canonicalGoonixRecordSignature(raw);
        SQLiteStmt insert;
        insert.create(db, "insert or ignore into GoonixBuildRecords "
            "(resolvedHash, resolvedDerivation, output, path, origin, "
            "relocationChecked, signature) select resolvedHash, resolvedDerivation, "
            "output, path, origin, relocationChecked, ?2 from GoonixBuildRecords "
            "where id = ?1;");
        auto write = insert.use();
        write(id);
        if (sqlite3_bind_text(insert, 2, signature.data(), signature.size(),
                SQLITE_TRANSIENT) != SQLITE_OK)
            throwSQLiteError(db, "binding canonical record signature");
        write.exec();
        /* Either the canonical row was inserted or its twin already existed.
           The old raw row is redundant in both cases. */
        SQLiteStmt remove;
        remove.create(db, "delete from GoonixBuildRecords where id = ?;");
        remove.use()(id).exec();
    }
    txn.commit();
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
    const string signature = canonicalGoonixRecordSignature(record.signature);
    /* The row may be a legacy raw fact discovered after this store opened.
       Its stored bytes are not valid UTF-8, so compare decoded raw bytes as
       blobs rather than coercing them through a C string. */
    SQLiteStmt existing;
    existing.create(db, "select 1 from GoonixBuildRecords "
        "where resolvedHash = ?1 and resolvedDerivation = ?2 and output = ?3 "
        "and path = ?4 and origin = ?5 and relocationChecked = ?6 "
        "and (signature = ?7 or (substr(signature, 1, 1) = '(' "
        "and cast(signature as blob) = cast(?8 as blob))) limit 1;");
    auto found = existing.use();
    const string rawSignature = goonixBase64Decode(signature);
    found(record.resolvedHash)(record.resolvedDerivation)(record.output)
        (record.path)(record.origin)(record.relocationChecked ? 1 : 0)(signature);
    if (sqlite3_bind_blob(existing, 8, rawSignature.data(),
            rawSignature.size(), SQLITE_TRANSIENT) != SQLITE_OK)
        throwSQLiteError(db, "binding raw record signature for deduplication");
    if (found.next()) return;
    SQLiteStmt stmt;
    stmt.create(db, "insert or ignore into GoonixBuildRecords "
        "(resolvedHash, resolvedDerivation, output, path, origin, "
        "relocationChecked, signature) values (?, ?, ?, ?, ?, ?, ?);");
    stmt.use()(record.resolvedHash)(record.resolvedDerivation)
        (record.output)(record.path)(record.origin)
        (record.relocationChecked ? 1 : 0)(signature).exec();
}

static BuildRecord readRecord(SQLiteStmt::Use & use)
{
    auto signature = use.getStr(6);
    if (signature.starts_with("("))
        /* A pre-base64 record holds the signer's raw advanced S-expression.
           Preserve the read-side conversion for databases opened read-only. */
        signature = canonicalGoonixRecordSignature(signature);
    else {
        try {
            goonixBase64Decode(signature);
        } catch (Error & error) {
            throw InvalidRecordSignature(error.msg());
        }
    }
    return {use.getStr(0), use.getStr(1), use.getStr(2),
        use.getStr(3), use.getStr(4), use.getInt(5) != 0, signature};
}

/* A damaged row does not hide valid siblings in an aggregate query.  Direct
   verification still rejects the same signature.  Name the row by its
   resolved derivation, output and path so the warning is actionable. */
template<typename... Args>
static std::vector<BuildRecord> readRecords(sqlite3 * db, const string & sql,
    Args... arguments)
{
    SQLiteStmt stmt;
    stmt.create(db, sql);
    auto use = stmt.use();
    (use(arguments), ...);
    std::vector<BuildRecord> result;
    while (use.next()) {
        try {
            result.push_back(readRecord(use));
        } catch (InvalidRecordSignature & error) {
            printMsg(lvlError, std::format(
                "goonix: ignoring invalid record signature for `{}', output `{}', path `{}': {}",
                use.getStr(1), use.getStr(2), use.getStr(3), error.msg()));
        }
    }
    return result;
}

static const char * recordColumns =
    "resolvedHash, resolvedDerivation, output, path, "
    "origin, relocationChecked, signature";

std::vector<BuildRecord> BuildRecords::query(const string & resolvedHash,
    const string & output)
{
    return readRecords(db, std::format("select {} from GoonixBuildRecords "
        "where resolvedHash = ? and (? = '' or output = ?) order by id;",
        recordColumns), resolvedHash, output, output);
}

std::vector<BuildRecord> BuildRecords::queryByPath(const Path & path)
{
    return readRecords(db, std::format("select {} from GoonixBuildRecords "
        "where path = ? order by id;", recordColumns), path);
}

std::vector<BuildRecord> BuildRecords::queryByResolvedDerivation(const Path & resolved)
{
    return readRecords(db, std::format("select {} from GoonixBuildRecords "
        "where resolvedDerivation = ? order by id;", recordColumns), resolved);
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
