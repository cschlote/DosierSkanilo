/** Shared persistence helpers for archive-member content identities.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.archiveindex;

import d2sqlite3;

import std.typecons : Nullable;

import dosierarkivo.archive : archiveVirtualColumnSql;

/** Build the SQL predicate that selects virtual file references.
 *
 * The table alias is taken from the part before the last dot in
 * `columnExpression`, falling back to `file_refs` when no alias is present.
 *
 * Params:
 *     columnExpression = SQL column expression such as `f.relative_path`.
 * Returns: A predicate of the form `(alias.is_virtual = 1)`.
 */
string isVirtualFileReferenceSql(string columnExpression)
{
    import std.string : lastIndexOf;

    auto tableAlias = columnExpression;
    const separator = tableAlias.lastIndexOf('.');
    if (separator != -1)
        tableAlias = tableAlias[0 .. separator];
    else
        tableAlias = "file_refs";
    return "(" ~ tableAlias ~ ".is_virtual = 1)";
}

@("virtual reference predicate selects the stored generated column")
unittest
{
    assert(isVirtualFileReferenceSql("f.relative_path")
        == "(f.is_virtual = 1)");
    assert(isVirtualFileReferenceSql("relative_path")
        == "(file_refs.is_virtual = 1)");

    auto db = Database(":memory:");
    db.execute("CREATE TABLE file_refs (relative_path TEXT NOT NULL, "
        ~ "is_virtual INTEGER GENERATED ALWAYS AS ("
        ~ archiveVirtualColumnSql() ~ ") VIRTUAL)");
    db.execute("INSERT INTO file_refs (relative_path) VALUES (?)",
        "plain!!/physical.txt");
    db.execute("INSERT INTO file_refs (relative_path) VALUES (?)",
        "archive.zip!/member.txt");
    db.execute("INSERT INTO file_refs (relative_path) VALUES (?)",
        "literal!!!/archive.zip");
    auto result = db.execute("SELECT count(*) FROM file_refs f WHERE "
        ~ isVirtualFileReferenceSql("f.relative_path"));
    assert(result.oneValue!long == 2);
}

/**
 * Reuse an existing blob for a fully fingerprinted archive member, or create a
 * content row for it. A zero result means deep checksums are incomplete.
 *
 * Params:
 *     db = Open repository database.
 *     size = Uncompressed member size in bytes.
 *     md5 = Complete MD5 digest, or `Nullable.init` when unavailable.
 *     sha1 = Complete SHA-1 digest, or `Nullable.init` when unavailable.
 *     xxh64 = Complete xxh64 digest, or `Nullable.init` when unavailable.
 * Returns: The matching or newly inserted blob ID, or `0` when any digest is
 *     missing or has the wrong length.
 */
long ensureArchiveMemberBlob(ref Database db, long size, Nullable!Blob md5,
    Nullable!Blob sha1, Nullable!Blob xxh64)
{
    if (md5.isNull || sha1.isNull || xxh64.isNull
        || md5.get.length != 16 || sha1.get.length != 20 || xxh64.get.length != 8)
        return 0;

    auto existing = db.execute("SELECT id FROM blobs WHERE file_size = ? "
        ~ "AND md5 = ? AND sha1 = ? AND xxh64 = ? ORDER BY id LIMIT 1",
        size, md5, sha1, xxh64);
    if (!existing.empty)
        return existing.front.peek!long(0);

    db.execute("INSERT INTO blobs (file_size, md5, sha1, xxh64) "
        ~ "VALUES (?, ?, ?, ?)", size, md5, sha1, xxh64);
    return db.lastInsertRowid;
}

/** Count content rows that have no ordinary file reference.
 *
 * Params:
 *     db = Open repository database.
 * Returns: Number of unreferenced blob rows.
 */
size_t countUnreachableBlobs(ref Database db)
{
    return cast(size_t) db.execute("SELECT count(*) FROM blobs "
        ~ "WHERE id NOT IN (SELECT blob_id FROM file_refs)")
        .oneValue!long;
}

/** Remove content rows that no physical or virtual reference points to.
 *
 * Params:
 *     db = Open repository database.
 * Returns: Number of blob rows deleted.
 */
size_t deleteUnreachableBlobs(ref Database db)
{
    db.execute("DELETE FROM blobs WHERE NOT EXISTS ("
        ~ "SELECT 1 FROM file_refs f WHERE f.blob_id = blobs.id)");
    return cast(size_t) db.changes;
}

/** Prefer an existing content blob when references have complete equal digests.
 *
 * Params:
 *     db = Open repository database.
 */
void resolveArchiveMemberBlobLinks(ref Database db)
{
    if (db.execute("SELECT 1 FROM file_refs WHERE "
        ~ isVirtualFileReferenceSql("relative_path") ~ " LIMIT 1").empty)
        return;
    db.execute("UPDATE file_refs SET blob_id = ("
        ~ "SELECT b.id FROM blobs b WHERE b.file_size = (SELECT c.file_size "
        ~ "FROM blobs c WHERE c.id = file_refs.blob_id) AND b.md5 = (SELECT c.md5 "
        ~ "FROM blobs c WHERE c.id = file_refs.blob_id) AND b.sha1 = (SELECT c.sha1 "
        ~ "FROM blobs c WHERE c.id = file_refs.blob_id) AND b.xxh64 = (SELECT c.xxh64 "
        ~ "FROM blobs c WHERE c.id = file_refs.blob_id) ORDER BY b.id LIMIT 1) "
        ~ "WHERE " ~ isVirtualFileReferenceSql("file_refs.relative_path") ~ " "
        ~ "AND EXISTS (SELECT 1 FROM blobs c WHERE c.id = file_refs.blob_id "
        ~ "AND c.md5 IS NOT NULL AND c.sha1 IS NOT NULL AND c.xxh64 IS NOT NULL)");
}
