/** Shared persistence helpers for archive-member content identities. */
module dosierskanilo.repository.archiveindex;

import d2sqlite3;

import std.typecons : Nullable;

/** SQL predicate recognizing canonical virtual paths while honoring `!!` escapes. */
string isVirtualFileReferenceSql(string columnExpression)
{
    return "instr(replace(" ~ columnExpression ~ ", '!!', ''), '!/') > 0";
}

@("virtual path SQL predicate recognizes escaped separators")
unittest
{
    auto db = Database(":memory:");
    bool isVirtual(string path)
    {
        return db.execute("SELECT " ~ isVirtualFileReferenceSql("?"), path)
            .oneValue!long != 0;
    }

    assert(!isVirtual("plain!!/physical.txt"));
    assert(!isVirtual("double!!!!/physical.txt"));
    assert(isVirtual("archive.zip!/member.txt"));
    assert(isVirtual("literal!!!/archive.zip"));
    assert(isVirtual("literal!!!/archive.zip!/member.txt"));
}

/**
 * Reuse an existing blob for a fully fingerprinted archive member, or create a
 * content row for it. A zero result means deep checksums are incomplete.
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

/** Count content rows that have no ordinary file reference. */
size_t countUnreachableBlobs(ref Database db)
{
    return cast(size_t) db.execute("SELECT count(*) FROM blobs "
        ~ "WHERE id NOT IN (SELECT blob_id FROM file_refs)")
        .oneValue!long;
}

/** Remove content rows that no physical or virtual reference points to. */
size_t deleteUnreachableBlobs(ref Database db)
{
    auto removed = countUnreachableBlobs(db);
    db.execute("DELETE FROM blobs WHERE id NOT IN "
        ~ "(SELECT blob_id FROM file_refs)");
    return removed;
}

/** Prefer an existing content blob when references have complete equal digests. */
void resolveArchiveMemberBlobLinks(ref Database db)
{
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
