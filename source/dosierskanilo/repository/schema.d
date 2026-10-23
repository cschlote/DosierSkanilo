/** Internal SQLite schema and migration handling. */
module dosierskanilo.repository.schema;

import d2sqlite3;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import dosierarkivo.archive : appendArchiveVirtualPath, archiveIndexVersion,
    escapeArchiveVirtualPath, normalizeArchiveEntryPath;
import dosierskanilo.repository.archiveindex : ensureArchiveMemberBlob,
    resolveArchiveMemberBlobLinks;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.types;

private enum initialSchema = q"SQL
CREATE TABLE IF NOT EXISTS repository (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    root_path TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    media_info_version TEXT,
    file_utility_version TEXT
);

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS directories (
    id INTEGER PRIMARY KEY,
    parent_id INTEGER REFERENCES directories(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS blobs (
    id INTEGER PRIMARY KEY,
    file_size INTEGER NOT NULL,
    md5 BLOB,
    sha1 BLOB,
    xxh64 BLOB,
    file_type TEXT
);

CREATE TABLE IF NOT EXISTS file_refs (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    directory_id INTEGER REFERENCES directories(id) ON DELETE SET NULL,
    relative_path TEXT NOT NULL UNIQUE,
    time_last_modified TEXT,
    exists_on_disk INTEGER NOT NULL DEFAULT 1 CHECK (exists_on_disk IN (0, 1)),
    last_seen_at TEXT
);

CREATE TABLE IF NOT EXISTS metadata_status (
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    metadata_kind TEXT NOT NULL,
    state TEXT NOT NULL,
    extractor_version TEXT,
    scanned_at TEXT,
    error_message TEXT,
    PRIMARY KEY (blob_id, metadata_kind)
);

CREATE TABLE IF NOT EXISTS media_signatures (
    blob_id INTEGER PRIMARY KEY REFERENCES blobs(id) ON DELETE CASCADE,
    extractor_version TEXT,
    scanned_at TEXT
);

CREATE TABLE IF NOT EXISTS media_image_streams (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    stream_index INTEGER NOT NULL,
    format TEXT,
    width INTEGER NOT NULL DEFAULT 0,
    height INTEGER NOT NULL DEFAULT 0,
    UNIQUE (blob_id, stream_index)
);

CREATE TABLE IF NOT EXISTS media_video_streams (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    stream_index INTEGER NOT NULL,
    language TEXT,
    format TEXT,
    width INTEGER NOT NULL DEFAULT 0,
    height INTEGER NOT NULL DEFAULT 0,
    frame_rate REAL NOT NULL DEFAULT 0,
    bit_rate INTEGER NOT NULL DEFAULT 0,
    duration TEXT,
    UNIQUE (blob_id, stream_index)
);

CREATE TABLE IF NOT EXISTS media_audio_streams (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    stream_index INTEGER NOT NULL,
    language TEXT,
    format TEXT,
    channels INTEGER NOT NULL DEFAULT 0,
    bit_rate INTEGER NOT NULL DEFAULT 0,
    duration TEXT,
    UNIQUE (blob_id, stream_index)
);

CREATE TABLE IF NOT EXISTS media_text_streams (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    stream_index INTEGER NOT NULL,
    language TEXT,
    format TEXT,
    frame_rate REAL NOT NULL DEFAULT 0,
    bit_rate INTEGER NOT NULL DEFAULT 0,
    duration TEXT,
    UNIQUE (blob_id, stream_index)
);

CREATE TABLE IF NOT EXISTS archive_entries (
    id INTEGER PRIMARY KEY,
    blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE,
    file_name TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    time_last_modified TEXT,
    md5 BLOB,
    sha1 BLOB,
    xxh64 BLOB,
    UNIQUE (blob_id, file_name)
);

CREATE TABLE IF NOT EXISTS torrent_info (
    blob_id INTEGER PRIMARY KEY REFERENCES blobs(id) ON DELETE CASCADE,
    name TEXT,
    magnet_uri TEXT,
    total_size INTEGER NOT NULL DEFAULT 0,
    is_multi_file INTEGER NOT NULL DEFAULT 0 CHECK (is_multi_file IN (0, 1)),
    info_hash_hex TEXT,
    announce TEXT,
    piece_length INTEGER NOT NULL DEFAULT 0,
    pieces_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS torrent_files (
    id INTEGER PRIMARY KEY,
    torrent_blob_id INTEGER NOT NULL REFERENCES torrent_info(blob_id)
        ON DELETE CASCADE,
    file_index INTEGER NOT NULL,
    relative_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    UNIQUE (torrent_blob_id, file_index)
);

CREATE INDEX IF NOT EXISTS idx_directories_parent
    ON directories(parent_id);
CREATE INDEX IF NOT EXISTS idx_file_refs_blob
    ON file_refs(blob_id);
CREATE INDEX IF NOT EXISTS idx_file_refs_directory
    ON file_refs(directory_id);
CREATE INDEX IF NOT EXISTS idx_blobs_size_sha1
    ON blobs(file_size, sha1);
CREATE INDEX IF NOT EXISTS idx_archive_entries_blob
    ON archive_entries(blob_id);
SQL";

/** Apply all schema migrations required by the current library. */
void migrate(ref Database db, string now)
{
    db.execute("PRAGMA foreign_keys = ON");
    db.execute("CREATE TABLE IF NOT EXISTS schema_migrations ("
        ~ "version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");

    ulong schemaVersion;
    {
        auto result = db.execute(
            "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
        if (!result.empty)
            schemaVersion = cast(ulong) result.front.peek!long(0);
    }

    if (schemaVersion > currentRepositorySchemaVersion)
        throw new RepositoryException("Repository schema is newer than this "
            ~ "application: " ~ to!string(schemaVersion));

    if (schemaVersion == 0)
    {
        try
        {
            db.begin();
            db.run(initialSchema);
            db.execute("INSERT INTO schema_migrations (version, applied_at) "
                ~ "VALUES (1, ?)", now);
            db.commit();
            schemaVersion = 1;
        }
        catch (Exception ex)
        {
            try
                db.rollback();
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    if (schemaVersion == 1)
    {
        try
        {
            db.begin();
            db.execute("CREATE TABLE archive_passwords ("
                ~ "blob_id INTEGER PRIMARY KEY REFERENCES blobs(id) ON DELETE CASCADE, "
                ~ "password TEXT NOT NULL)");
            db.execute("INSERT INTO schema_migrations (version, applied_at) "
                ~ "VALUES (2, ?)", now);
            db.execute("UPDATE repository SET schema_version = 2 WHERE id = 1");
            db.commit();
            schemaVersion = 2;
        }
        catch (Exception ex)
        {
            try
                db.rollback();
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    if (schemaVersion == 2)
    {
        try
        {
            db.begin();
            db.execute("ALTER TABLE archive_entries RENAME TO archive_entries_v2");
            db.execute("CREATE TABLE archive_entries ("
                ~ "id INTEGER PRIMARY KEY, "
                ~ "blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE, "
                ~ "entry_index INTEGER NOT NULL, "
                ~ "occurrence INTEGER NOT NULL DEFAULT 0, "
                ~ "file_name TEXT NOT NULL, "
                ~ "normalized_path TEXT NOT NULL, "
                ~ "path_safe INTEGER NOT NULL DEFAULT 1 CHECK (path_safe IN (0, 1)), "
                ~ "is_directory INTEGER NOT NULL DEFAULT 0 CHECK (is_directory IN (0, 1)), "
                ~ "file_size INTEGER NOT NULL, time_last_modified TEXT, "
                ~ "md5 BLOB, sha1 BLOB, xxh64 BLOB, "
                ~ "content_blob_id INTEGER REFERENCES blobs(id) ON DELETE SET NULL, "
                ~ "UNIQUE (blob_id, entry_index), "
                ~ "UNIQUE (blob_id, path_safe, normalized_path, occurrence))");

            copyLegacyArchiveEntries(db);
            resolveArchiveMemberBlobLinks(db);
            db.execute("DROP TABLE archive_entries_v2");
            db.execute("CREATE INDEX idx_archive_entries_blob ON archive_entries(blob_id)");
            db.execute("CREATE TABLE archive_indexes ("
                ~ "blob_id INTEGER PRIMARY KEY REFERENCES blobs(id) ON DELETE CASCADE, "
                ~ "indexer_version TEXT NOT NULL, indexed_at TEXT NOT NULL, "
                ~ "deep_scanned INTEGER NOT NULL DEFAULT 0 "
                ~ "CHECK (deep_scanned IN (0, 1)))");
            db.execute("INSERT OR IGNORE INTO archive_indexes "
                ~ "(blob_id, indexer_version, indexed_at) "
                ~ "SELECT DISTINCT blob_id, 'legacy-v2', ? FROM archive_entries", now);
            db.execute("INSERT OR IGNORE INTO archive_indexes "
                ~ "(blob_id, indexer_version, indexed_at) "
                ~ "SELECT blob_id, 'legacy-v2', ? FROM metadata_status "
                ~ "WHERE metadata_kind = 'archives' AND state IN ('completed', 'empty')",
                now);
            db.execute("INSERT INTO schema_migrations (version, applied_at) "
                ~ "VALUES (3, ?)", now);
            db.execute("UPDATE repository SET schema_version = 3 WHERE id = 1");
            db.commit();
            schemaVersion = 3;
        }
        catch (Exception ex)
        {
            try
                db.rollback();
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    if (schemaVersion == 3)
    {
        try
        {
            db.begin();
            migrateArchiveRowsToVirtualReferences(db, now);
            db.execute("DROP TABLE archive_indexes");
            db.execute("DROP TABLE archive_entries");
            db.execute("DELETE FROM blobs WHERE id NOT IN "
                ~ "(SELECT blob_id FROM file_refs)");
            db.execute("INSERT INTO schema_migrations (version, applied_at) "
                ~ "VALUES (4, ?)", now);
            db.execute("UPDATE repository SET schema_version = 4 WHERE id = 1");
            db.commit();
            schemaVersion = 4;
        }
        catch (Exception ex)
        {
            try
                db.rollback();
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    /* Keep SQLite's own version in sync with the migration table so external
     * tools can inspect the schema without reading `schema_migrations`. Only
     * write when it changed, so opening an initialized repository stays
     * read-only. */
    ulong pragmaVersion;
    {
        auto result = db.execute("PRAGMA user_version");
        if (!result.empty)
            pragmaVersion = cast(ulong) result.front.peek!long(0);
    }
    if (pragmaVersion != schemaVersion)
        db.execute("PRAGMA user_version = " ~ to!string(schemaVersion));
}

private struct MigrationFileReference
{
    long id;
    long blobId;
    Nullable!long directoryId;
    string relativePath;
    string modifiedAt;
    bool existsOnDisk;
    string lastSeenAt;
    size_t depth;
}

private struct MigrationArchiveEntry
{
    size_t entryIndex;
    size_t occurrence;
    string fileName;
    string normalizedPath;
    bool pathSafe;
    bool isDirectory;
    long fileSize;
    string modifiedAt;
    Nullable!Blob md5;
    Nullable!Blob sha1;
    Nullable!Blob xxh64;
    Nullable!long contentBlobId;
}

private void migrateArchiveRowsToVirtualReferences(ref Database db, string now)
{
    MigrationFileReference[] containers;
    foreach (row; db.execute("SELECT id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at FROM file_refs "
        ~ "ORDER BY id"))
    {
        MigrationFileReference reference;
        reference.id = row.peek!long(0);
        reference.blobId = row.peek!long(1);
        reference.directoryId = row.peek!(Nullable!long)(2);
        reference.relativePath = row.peek!string(3).dup;
        auto modified = row.peek!(Nullable!string)(4);
        reference.modifiedAt = modified.isNull ? "" : modified.get.idup;
        reference.existsOnDisk = row.peek!long(5) != 0;
        auto seen = row.peek!(Nullable!string)(6);
        reference.lastSeenAt = seen.isNull ? "" : seen.get.idup;
        const auto canonical = escapeArchiveVirtualPath(reference.relativePath);
        if (canonical != reference.relativePath)
        {
            db.execute("UPDATE file_refs SET relative_path = ? WHERE id = ?",
                canonical, reference.id);
            reference.relativePath = canonical;
        }
        containers ~= reference;
    }

    MigrationArchiveEntry[][long] entriesByContainer;
    foreach (row; db.execute("SELECT blob_id, entry_index, occurrence, file_name, "
        ~ "normalized_path, path_safe, is_directory, file_size, "
        ~ "time_last_modified, md5, sha1, xxh64, content_blob_id "
        ~ "FROM archive_entries ORDER BY blob_id, entry_index"))
    {
        MigrationArchiveEntry entry;
        const auto blobId = row.peek!long(0);
        entry.entryIndex = cast(size_t) row.peek!long(1);
        entry.occurrence = cast(size_t) row.peek!long(2);
        entry.fileName = row.peek!string(3).dup;
        entry.normalizedPath = row.peek!string(4).dup;
        entry.pathSafe = row.peek!long(5) != 0;
        entry.isDirectory = row.peek!long(6) != 0;
        entry.fileSize = row.peek!long(7);
        auto modified = row.peek!(Nullable!string)(8);
        entry.modifiedAt = modified.isNull ? "" : modified.get.idup;
        const auto md5 = row.peek!(Nullable!Blob)(9);
        const auto sha1 = row.peek!(Nullable!Blob)(10);
        const auto xxh64 = row.peek!(Nullable!Blob)(11);
        if (!md5.isNull) entry.md5 = Nullable!Blob(md5.get.dup);
        if (!sha1.isNull) entry.sha1 = Nullable!Blob(sha1.get.dup);
        if (!xxh64.isNull) entry.xxh64 = Nullable!Blob(xxh64.get.dup);
        const auto contentBlobId = row.peek!(Nullable!long)(12);
        if (!contentBlobId.isNull)
            entry.contentBlobId = Nullable!long(contentBlobId.get);
        entriesByContainer[blobId] ~= entry;
    }

    size_t referenceIndex;
    while (referenceIndex < containers.length)
    {
        const auto container = containers[referenceIndex++];
        auto entries = container.blobId in entriesByContainer;
        if (entries is null)
            continue;
        enforce(container.depth < 32,
            "Nested archive migration exceeds the maximum path depth.");

        size_t[string] pathCounts;
        foreach (entry; *entries)
        {
            bool safe;
            bool isDirectory;
            const auto normalized = normalizeArchiveEntryPath(
                entry.normalizedPath, safe, isDirectory);
            if (entry.pathSafe && safe && !entry.isDirectory && !isDirectory
                && normalized == entry.normalizedPath)
                pathCounts[normalized] = pathCounts.get(normalized, 0) + 1;
        }

        foreach (entry; *entries)
        {
            bool safe;
            bool isDirectory;
            const auto normalizedPath = normalizeArchiveEntryPath(
                entry.normalizedPath, safe, isDirectory);
            if (!entry.pathSafe || !safe || entry.isDirectory || isDirectory
                || normalizedPath.length == 0
                || normalizedPath != entry.normalizedPath)
                continue;
            auto memberBlobId = entry.contentBlobId.isNull ? 0
                : entry.contentBlobId.get;
            if (memberBlobId == 0)
            {
                memberBlobId = ensureArchiveMemberBlob(db, entry.fileSize,
                    entry.md5, entry.sha1, entry.xxh64);
                if (memberBlobId == 0)
                {
                    db.execute("INSERT INTO blobs (file_size, md5, sha1, xxh64) "
                        ~ "VALUES (?, ?, ?, ?)", entry.fileSize, entry.md5,
                        entry.sha1, entry.xxh64);
                    memberBlobId = db.lastInsertRowid;
                }
            }

            const auto occurrence = pathCounts.get(entry.normalizedPath, 0) > 1
                ? entry.occurrence : size_t.max;
            const auto virtualPath = appendArchiveVirtualPath(
                container.relativePath, normalizedPath, occurrence);
            Nullable!string modifiedAt;
            if (entry.modifiedAt.length > 0)
                modifiedAt = Nullable!string(entry.modifiedAt);
            Nullable!string lastSeenAt;
            if (container.lastSeenAt.length > 0)
                lastSeenAt = Nullable!string(container.lastSeenAt);
            db.execute("INSERT OR IGNORE INTO file_refs (blob_id, directory_id, "
                ~ "relative_path, time_last_modified, exists_on_disk, last_seen_at) "
                ~ "VALUES (?, ?, ?, ?, ?, ?)", memberBlobId,
                container.directoryId, virtualPath, modifiedAt,
                container.existsOnDisk ? 1 : 0, lastSeenAt);
            if (db.changes > 0)
            {
                MigrationFileReference memberReference;
                memberReference.id = db.lastInsertRowid;
                memberReference.blobId = memberBlobId;
                memberReference.directoryId = container.directoryId;
                memberReference.relativePath = virtualPath;
                memberReference.modifiedAt = entry.modifiedAt;
                memberReference.existsOnDisk = container.existsOnDisk;
                memberReference.lastSeenAt = container.lastSeenAt;
                memberReference.depth = container.depth + 1;
                containers ~= memberReference;
            }
        }
    }

    foreach (row; db.execute("SELECT i.blob_id, i.indexer_version, i.indexed_at, "
        ~ "i.deep_scanned, (SELECT count(*) FROM archive_entries e "
        ~ "WHERE e.blob_id = i.blob_id) FROM archive_indexes i"))
    {
        const auto blobId = row.peek!long(0);
        const auto indexerVersion = row.peek!string(1);
        const auto indexedAt = row.peek!string(2);
        const bool deep = row.peek!long(3) != 0;
        const bool hasEntries = row.peek!long(4) != 0;
        const auto extractorVersion = indexerVersion ~ (deep ? ":deep" : ":shallow");
        const auto state = hasEntries ? "completed" : "empty";
        db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
            ~ "extractor_version, scanned_at, error_message) VALUES (?, 'archives', "
            ~ "?, ?, ?, NULL) ON CONFLICT(blob_id, metadata_kind) DO UPDATE SET "
            ~ "state = excluded.state, extractor_version = excluded.extractor_version, "
            ~ "scanned_at = excluded.scanned_at, error_message = NULL",
            blobId, state, extractorVersion, indexedAt.length > 0 ? indexedAt : now);
    }
    db.execute("UPDATE metadata_status SET extractor_version = "
        ~ "COALESCE(extractor_version, 'legacy-unknown:shallow') "
        ~ "WHERE metadata_kind = 'archives' AND extractor_version IS NULL");
}

private void copyLegacyArchiveEntries(ref Database db)
{
    struct LegacyEntry
    {
        long id;
        long blobId;
        string name;
        long size;
        Nullable!string modified;
        Nullable!Blob md5;
        Nullable!Blob sha1;
        Nullable!Blob xxh64;
    }

    LegacyEntry[] legacyEntries;
    {
        foreach (row; db.execute("SELECT id, blob_id, file_name, file_size, "
            ~ "time_last_modified, md5, sha1, xxh64 FROM archive_entries_v2 "
            ~ "ORDER BY blob_id, id"))
        {
            LegacyEntry entry;
            entry.id = row.peek!long(0);
            entry.blobId = row.peek!long(1);
            entry.name = row.peek!string(2).dup;
            entry.size = row.peek!long(3);
            const auto modified = row.peek!(Nullable!string)(4);
            if (!modified.isNull)
                entry.modified = Nullable!string(modified.get.dup);
            const auto md5 = row.peek!(Nullable!Blob)(5);
            const auto sha1 = row.peek!(Nullable!Blob)(6);
            const auto xxh64 = row.peek!(Nullable!Blob)(7);
            if (!md5.isNull) entry.md5 = Nullable!Blob(md5.get.dup);
            if (!sha1.isNull) entry.sha1 = Nullable!Blob(sha1.get.dup);
            if (!xxh64.isNull) entry.xxh64 = Nullable!Blob(xxh64.get.dup);
            legacyEntries ~= entry;
        }
    }

    long currentBlobId = -1;
    size_t entryIndex;
    size_t[string] occurrences;
    foreach (entry; legacyEntries)
    {
        if (entry.blobId != currentBlobId)
        {
            currentBlobId = entry.blobId;
            entryIndex = 0;
            occurrences = null;
        }
        bool pathSafe;
        bool isDirectory;
        const auto normalized = normalizeArchiveEntryPath(entry.name, pathSafe,
            isDirectory);
        auto storedPath = pathSafe ? normalized : entry.name;
        auto occurrenceKey = (pathSafe ? "safe\0" : "unsafe\0") ~ storedPath;
        auto occurrence = occurrences.get(occurrenceKey, 0);
        occurrences[occurrenceKey] = occurrence + 1;
        db.execute("INSERT INTO archive_entries (id, blob_id, entry_index, "
            ~ "occurrence, file_name, normalized_path, path_safe, is_directory, "
            ~ "file_size, time_last_modified, md5, sha1, xxh64, content_blob_id) "
            ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            entry.id, entry.blobId, cast(long) entryIndex,
            cast(long) occurrence, entry.name, storedPath, pathSafe ? 1 : 0,
            isDirectory ? 1 : 0, entry.size, entry.modified, entry.md5,
            entry.sha1, entry.xxh64,
            nullableArchiveMemberBlob(db, entry.size, entry.md5, entry.sha1,
                entry.xxh64));
        ++entryIndex;
    }
}

private Nullable!long nullableArchiveMemberBlob(ref Database db, long size,
    Nullable!Blob md5, Nullable!Blob sha1, Nullable!Blob xxh64)
{
    auto id = ensureArchiveMemberBlob(db, size, md5, sha1, xxh64);
    Nullable!long result;
    if (id > 0)
        result = id;
    return result;
}

@("schema migration creates the initial repository tables")
unittest
{
    import std.string : toLower;

    auto db = Database(":memory:");
    migrate(db, "2026-09-17T00:00:00");

    assert(db.execute("PRAGMA foreign_keys").oneValue!long == 1);
    assert(db.execute("SELECT version FROM schema_migrations "
        ~ "ORDER BY version DESC LIMIT 1")
        .oneValue!long == currentRepositorySchemaVersion);

    bool[string] expectedTables = [
        "repository": true,
        "schema_migrations": true,
        "directories": true,
        "blobs": true,
        "file_refs": true,
        "metadata_status": true,
        "media_signatures": true,
        "media_image_streams": true,
        "media_video_streams": true,
        "media_audio_streams": true,
        "media_text_streams": true,
        "archive_passwords": true,
        "torrent_info": true,
        "torrent_files": true
    ];

    auto result = db.execute("SELECT name FROM sqlite_master "
        ~ "WHERE type = 'table'");
    foreach (row; result)
    {
        auto tableName = row.peek!string(0).toLower;
        expectedTables.remove(tableName);
    }
    assert(expectedTables.length == 0, "Missing repository schema tables.");
}

@("schema migration upgrades version 1 through stable archive entry indexes")
unittest
{
    auto db = Database(":memory:");
    db.execute("PRAGMA foreign_keys = ON");
    db.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, "
        ~ "applied_at TEXT NOT NULL)");
    db.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, file_size INTEGER, "
        ~ "md5 BLOB, sha1 BLOB, xxh64 BLOB)");
    db.execute("CREATE TABLE directories (id INTEGER PRIMARY KEY, parent_id INTEGER, "
        ~ "relative_path TEXT, name TEXT)");
    db.execute("CREATE TABLE file_refs (id INTEGER PRIMARY KEY, blob_id INTEGER, "
        ~ "directory_id INTEGER, relative_path TEXT, time_last_modified TEXT, "
        ~ "exists_on_disk INTEGER NOT NULL DEFAULT 1, last_seen_at TEXT)");
    db.execute("CREATE TABLE repository (id INTEGER PRIMARY KEY, "
        ~ "schema_version INTEGER NOT NULL)");
    db.execute("CREATE TABLE metadata_status (blob_id INTEGER NOT NULL, "
        ~ "metadata_kind TEXT NOT NULL, state TEXT NOT NULL, extractor_version TEXT, "
        ~ "scanned_at TEXT, error_message TEXT, PRIMARY KEY (blob_id, metadata_kind))");
    db.execute("CREATE TABLE archive_entries (id INTEGER PRIMARY KEY, "
        ~ "blob_id INTEGER NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL, "
        ~ "time_last_modified TEXT, md5 BLOB, sha1 BLOB, xxh64 BLOB, "
        ~ "UNIQUE (blob_id, file_name))");
    db.execute("INSERT INTO repository (id, schema_version) VALUES (1, 1)");
    db.execute("INSERT INTO schema_migrations (version, applied_at) "
        ~ "VALUES (1, ?)", "2026-01-01T00:00:00");

    migrate(db, "2026-01-02T00:00:00");
    assert(db.execute("SELECT version FROM schema_migrations "
        ~ "ORDER BY version DESC LIMIT 1").oneValue!long
        == currentRepositorySchemaVersion);
    assert(db.execute("SELECT schema_version FROM repository WHERE id = 1")
        .oneValue!long == currentRepositorySchemaVersion);
    assert(!db.execute("PRAGMA foreign_key_list(archive_passwords)").empty);
    assert(db.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table' "
        ~ "AND name IN ('archive_entries', 'archive_indexes')")
        .oneValue!long == 0);
}

@("schema version 3 migration promotes archive rows to virtual file references")
unittest
{
    auto db = Database(":memory:");
    db.execute("PRAGMA foreign_keys = ON");
    db.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, "
        ~ "applied_at TEXT NOT NULL)");
    db.execute("CREATE TABLE repository (id INTEGER PRIMARY KEY, "
        ~ "schema_version INTEGER NOT NULL)");
    db.execute("CREATE TABLE directories (id INTEGER PRIMARY KEY, parent_id INTEGER, "
        ~ "relative_path TEXT, name TEXT)");
    db.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, file_size INTEGER NOT NULL, "
        ~ "md5 BLOB, sha1 BLOB, xxh64 BLOB, file_type TEXT)");
    db.execute("CREATE TABLE file_refs (id INTEGER PRIMARY KEY, blob_id INTEGER NOT NULL, "
        ~ "directory_id INTEGER, relative_path TEXT NOT NULL UNIQUE, "
        ~ "time_last_modified TEXT, exists_on_disk INTEGER NOT NULL DEFAULT 1, "
        ~ "last_seen_at TEXT)");
    db.execute("CREATE TABLE metadata_status (blob_id INTEGER NOT NULL, "
        ~ "metadata_kind TEXT NOT NULL, state TEXT NOT NULL, extractor_version TEXT, "
        ~ "scanned_at TEXT, error_message TEXT, PRIMARY KEY (blob_id, metadata_kind))");
    db.execute("CREATE TABLE archive_entries (id INTEGER PRIMARY KEY, "
        ~ "blob_id INTEGER NOT NULL REFERENCES blobs(id) ON DELETE CASCADE, "
        ~ "entry_index INTEGER NOT NULL, occurrence INTEGER NOT NULL, "
        ~ "file_name TEXT NOT NULL, normalized_path TEXT NOT NULL, "
        ~ "path_safe INTEGER NOT NULL, is_directory INTEGER NOT NULL, "
        ~ "file_size INTEGER NOT NULL, time_last_modified TEXT, "
        ~ "md5 BLOB, sha1 BLOB, xxh64 BLOB, "
        ~ "content_blob_id INTEGER REFERENCES blobs(id) ON DELETE SET NULL, "
        ~ "UNIQUE (blob_id, entry_index))");
    db.execute("CREATE TABLE archive_indexes (blob_id INTEGER PRIMARY KEY, "
        ~ "indexer_version TEXT NOT NULL, indexed_at TEXT NOT NULL, "
        ~ "deep_scanned INTEGER NOT NULL)");
    db.execute("INSERT INTO repository (id, schema_version) VALUES (1, 3)");
    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (4, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (7, 128), (8, 11), "
        ~ "(9, 64), (10, 5), (11, 0), (12, 32), (13, 3)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(99, 7, 4, 'archives/container!.zip', '2026-01-01T00:00:00', 1, ?), "
        ~ "(101, 11, 4, 'archives/empty!.zip', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00");
    db.execute("INSERT INTO schema_migrations (version, applied_at) "
        ~ "VALUES (3, ?)", "2026-01-01T00:00:00");
    db.execute("INSERT INTO archive_entries (id, blob_id, entry_index, occurrence, "
        ~ "file_name, normalized_path, path_safe, is_directory, file_size, "
        ~ "content_blob_id) VALUES "
        ~ "(19, 7, 0, 0, 'nested/readme.txt', 'nested/readme.txt', 1, 0, 11, 8), "
        ~ "(20, 7, 1, 1, 'nested/readme.txt', 'nested/readme.txt', 1, 0, 11, 8), "
        ~ "(21, 7, 2, 0, 'nested.zip', 'nested.zip', 1, 0, 64, 9), "
        ~ "(22, 7, 3, 0, '../unsafe.txt', '../unsafe.txt', 0, 0, 3, NULL), "
        ~ "(23, 7, 4, 0, 'folder/', 'folder', 1, 1, 0, NULL), "
        ~ "(24, 9, 0, 0, 'deep/readme.txt', 'deep/readme.txt', 1, 0, 5, 10), "
        ~ "(25, 12, 0, 0, 'orphan.txt', 'orphan.txt', 1, 0, 3, 13)");
    db.execute("INSERT INTO archive_indexes (blob_id, indexer_version, indexed_at, "
        ~ "deep_scanned) VALUES (7, 'legacy-indexer', '2026-01-01T00:00:00', 1), "
        ~ "(9, 'legacy-indexer', '2026-01-01T00:00:00', 1), "
        ~ "(11, 'legacy-indexer', '2026-01-01T00:00:00', 0), "
        ~ "(12, 'legacy-indexer', '2026-01-01T00:00:00', 1)");

    migrate(db, "2026-01-02T00:00:00");
    assert(db.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table' "
        ~ "AND name IN ('archive_entries', 'archive_indexes')")
        .oneValue!long == 0);
    assert(db.execute("SELECT schema_version FROM repository WHERE id = 1")
        .oneValue!long == currentRepositorySchemaVersion);
    assert(db.execute("SELECT relative_path FROM file_refs WHERE id = 99")
        .oneValue!string == "archives/container!!.zip");
    assert(db.execute("SELECT count(*) FROM file_refs").oneValue!long == 6);
    assert(db.execute("SELECT relative_path FROM file_refs WHERE id = 101")
        .oneValue!string == "archives/empty!!.zip");
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path = ? "
        ~ "AND directory_id = 4 AND blob_id = 8",
        "archives/container!!.zip!/nested/readme.txt!~0").oneValue!long == 1);
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path = ? "
        ~ "AND directory_id = 4 AND blob_id = 8",
        "archives/container!!.zip!/nested/readme.txt!~1").oneValue!long == 1);
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path = ? "
        ~ "AND directory_id = 4 AND blob_id = 10",
        "archives/container!!.zip!/nested.zip!/deep/readme.txt")
        .oneValue!long == 1);
    assert(db.execute("SELECT state FROM metadata_status WHERE blob_id = 7 "
        ~ "AND metadata_kind = 'archives'").oneValue!string == "completed");
    assert(db.execute("SELECT extractor_version FROM metadata_status "
        ~ "WHERE blob_id = 7 AND metadata_kind = 'archives'")
        .oneValue!string == "legacy-indexer:deep");
    assert(db.execute("SELECT state FROM metadata_status WHERE blob_id = 11 "
        ~ "AND metadata_kind = 'archives'").oneValue!string == "empty");
    assert(db.execute("SELECT count(*) FROM blobs WHERE id IN (12, 13)")
        .oneValue!long == 0);
}

@("schema migration upgrades version 2 through stable archive entry indexes")
unittest
{
    auto db = Database(":memory:");
    db.execute("PRAGMA foreign_keys = ON");
    db.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, "
        ~ "applied_at TEXT NOT NULL)");
    db.execute("CREATE TABLE repository (id INTEGER PRIMARY KEY, "
        ~ "schema_version INTEGER NOT NULL)");
    db.execute("CREATE TABLE directories (id INTEGER PRIMARY KEY, parent_id INTEGER, "
        ~ "relative_path TEXT, name TEXT)");
    db.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, file_size INTEGER NOT NULL, "
        ~ "md5 BLOB, sha1 BLOB, xxh64 BLOB, file_type TEXT)");
    db.execute("CREATE TABLE file_refs (id INTEGER PRIMARY KEY, blob_id INTEGER NOT NULL, "
        ~ "directory_id INTEGER, relative_path TEXT NOT NULL UNIQUE, "
        ~ "time_last_modified TEXT, exists_on_disk INTEGER NOT NULL DEFAULT 1, "
        ~ "last_seen_at TEXT)");
    db.execute("CREATE TABLE metadata_status (blob_id INTEGER NOT NULL, "
        ~ "metadata_kind TEXT NOT NULL, state TEXT NOT NULL, extractor_version TEXT, "
        ~ "scanned_at TEXT, error_message TEXT, PRIMARY KEY (blob_id, metadata_kind))");
    db.execute("CREATE TABLE archive_passwords (blob_id INTEGER PRIMARY KEY, "
        ~ "password TEXT NOT NULL)");
    db.execute("CREATE TABLE archive_entries (id INTEGER PRIMARY KEY, "
        ~ "blob_id INTEGER NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL, "
        ~ "time_last_modified TEXT, md5 BLOB, sha1 BLOB, xxh64 BLOB, "
        ~ "UNIQUE (blob_id, file_name))");
    db.execute("INSERT INTO repository (id, schema_version) VALUES (1, 2)");
    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (4, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (7, 128), (8, 11)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(99, 7, 4, 'archives/container!.zip', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO schema_migrations (version, applied_at) "
        ~ "VALUES (2, ?)", "2026-01-01T00:00:00");
    db.execute("INSERT INTO archive_entries (id, blob_id, file_name, file_size, "
        ~ "time_last_modified, md5, sha1, xxh64) VALUES "
        ~ "(19, 7, 'nested/readme.txt', 11, '2026-01-01T00:00:00', NULL, NULL, NULL)");

    migrate(db, "2026-01-02T00:00:00");

    assert(db.execute("SELECT version FROM schema_migrations "
        ~ "ORDER BY version DESC LIMIT 1").oneValue!long
        == currentRepositorySchemaVersion);
    assert(db.execute("SELECT schema_version FROM repository WHERE id = 1")
        .oneValue!long == currentRepositorySchemaVersion);
    assert(db.execute("SELECT relative_path FROM file_refs WHERE id = 99")
        .oneValue!string == "archives/container!!.zip");
    assert(db.execute("SELECT count(*) FROM file_refs").oneValue!long == 2);
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path = ?",
        "archives/container!!.zip!/nested/readme.txt").oneValue!long == 1);
    assert(db.execute("SELECT blob_id FROM file_refs WHERE relative_path = ?",
        "archives/container!!.zip!/nested/readme.txt").oneValue!long > 0);
    assert(db.execute("SELECT count(*) FROM sqlite_master WHERE type = 'table' "
        ~ "AND name IN ('archive_entries', 'archive_indexes')")
        .oneValue!long == 0);
}

@("schema migration rejects newer database versions")
unittest
{
    import std.exception : assertThrown;

    auto db = Database(":memory:");
    db.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, "
        ~ "applied_at TEXT NOT NULL)");
    db.execute("INSERT INTO schema_migrations (version, applied_at) "
        ~ "VALUES (99, ?)", "2026-01-01T00:00:00");
    assertThrown!RepositoryException(migrate(db, "2026-01-01T00:00:00"));
}
