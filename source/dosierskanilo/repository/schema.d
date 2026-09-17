/** Internal SQLite schema and migration handling. */
module dosierskanilo.repository.schema;

import d2sqlite3;

import std.conv : to;

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
    auto result = db.execute(
        "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
    if (!result.empty)
        schemaVersion = cast(ulong) result.front.peek!long(0);

    if (schemaVersion == currentRepositorySchemaVersion)
        return;
    if (schemaVersion > currentRepositorySchemaVersion)
        throw new RepositoryException("Repository schema is newer than this "
            ~ "application: " ~ to!string(schemaVersion));
    if (schemaVersion != 0)
        throw new RepositoryException("Unsupported repository schema version: "
            ~ to!string(schemaVersion));

    try
    {
        db.begin();
        db.run(initialSchema);
        db.execute("INSERT INTO schema_migrations (version, applied_at) "
            ~ "VALUES (?, ?)", cast(long) currentRepositorySchemaVersion, now);
        db.commit();
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

@("schema migration creates the initial repository tables")
unittest
{
    import std.string : toLower;

    auto db = Database(":memory:");
    migrate(db, "2026-09-17T00:00:00");

    assert(db.execute("PRAGMA foreign_keys").oneValue!long == 1);
    assert(db.execute("SELECT version FROM schema_migrations")
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
        "archive_entries": true,
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
