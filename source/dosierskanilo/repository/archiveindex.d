/** Shared persistence helpers for archive-member content identities. */
module dosierskanilo.repository.archiveindex;

import d2sqlite3;

import std.typecons : Nullable;

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

/** Count content rows reachable from physical references through archive indexes. */
size_t countUnreachableBlobs(ref Database db)
{
    return cast(size_t) db.execute("WITH RECURSIVE reachable(id) AS ("
        ~ "SELECT blob_id FROM file_refs UNION "
        ~ "SELECT entry.content_blob_id FROM archive_entries entry "
        ~ "JOIN reachable parent ON entry.blob_id = parent.id "
        ~ "WHERE entry.content_blob_id IS NOT NULL) "
        ~ "SELECT count(*) FROM blobs WHERE id NOT IN (SELECT id FROM reachable)")
        .oneValue!long;
}

/** Remove rows unreachable from physical references or nested archive members. */
size_t deleteUnreachableBlobs(ref Database db)
{
    auto removed = countUnreachableBlobs(db);
    db.execute("WITH RECURSIVE reachable(id) AS ("
        ~ "SELECT blob_id FROM file_refs UNION "
        ~ "SELECT entry.content_blob_id FROM archive_entries entry "
        ~ "JOIN reachable parent ON entry.blob_id = parent.id "
        ~ "WHERE entry.content_blob_id IS NOT NULL) "
        ~ "DELETE FROM blobs WHERE id NOT IN (SELECT id FROM reachable)");
    return removed;
}

/** Prefer a matching physical blob when an archive member and file share a digest. */
void resolveArchiveMemberBlobLinks(ref Database db)
{
    db.execute("UPDATE archive_entries SET content_blob_id = ("
        ~ "SELECT b.id FROM blobs b JOIN file_refs f ON f.blob_id = b.id "
        ~ "WHERE b.file_size = archive_entries.file_size "
        ~ "AND b.md5 = archive_entries.md5 AND b.sha1 = archive_entries.sha1 "
        ~ "AND b.xxh64 = archive_entries.xxh64 ORDER BY b.id LIMIT 1) "
        ~ "WHERE md5 IS NOT NULL AND sha1 IS NOT NULL AND xxh64 IS NOT NULL "
        ~ "AND EXISTS (SELECT 1 FROM blobs b JOIN file_refs f ON f.blob_id = b.id "
        ~ "WHERE b.file_size = archive_entries.file_size "
        ~ "AND b.md5 = archive_entries.md5 AND b.sha1 = archive_entries.sha1 "
        ~ "AND b.xxh64 = archive_entries.xxh64)");
}
