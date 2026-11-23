/** Repository lifecycle: initialize, open, restore, backup, and close.
 *
 * Creation and discovery of `.dosierskanilo` repositories, safe
 * reinitialization and restore, status reporting, and handle shutdown.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.lifecycle;

import dosierskanilo.repository.transfer : currentTimestamp;
import d2sqlite3;
import std.datetime.systime : Clock;
import std.conv : to;
import std.file : SpanMode, copy, dirEntries, exists, getSize, isDir, isFile,
    mkdirRecurse, remove, rename;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName;
import std.string : empty, endsWith, replace, toLower;
import std.stdio : File;
import std.typecons : Nullable;
import dosierskanilo.catalogstatus : CatalogStatus;
import dosierskanilo.operations : OperationStorageMode;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.filesystem :
    isUnsupportedRepositoryFilesystemType, repositoryFilesystemType;
import dosierskanilo.repository.schema : initialSchema, migrate;
import dosierskanilo.repository.types;
import dosierskanilo.repository.repository : Repository;

/** Members of `Repository` in the lifecycle area; mixed into the class. */
mixin template RepositoryLifecycle()
{
    /** Open an existing repository at `rootPath`.
     *
     * Enables the requested SQLite settings, migrates the schema, and ensures
     * the singleton repository row exists.
     *
     * Params:
     *     rootPath = Repository root containing the metadata directory.
     *     options = Database and schema options.
     * Returns: An open repository handle.
     * Throws: `RepositoryException` when the path is not a repository.
     */
    package static Repository openRoot(string rootPath, RepositoryOptions options)
    {
        ensureSupportedFilesystem(rootPath);
        auto paths = RepositoryPaths.fromRoot(rootPath);
        ensureSupportedFilesystem(paths.metadataPath);
        ensureSupportedFilesystem(paths.databasePath);
        if (!exists(paths.metadataPath))
            throw new RepositoryException("Not a DosierSkanilo repository: "
                ~ rootPath);

        auto db = Database(paths.databasePath);
        try
        {
            configure(db, options);
            migrate(db, currentTimestamp());
            ensureRepositoryRow(db, rootPath);
            return new Repository(db, paths);
        }
        catch (Exception ex)
        {
            try
                db.close();
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    /** Apply the SQLite connection settings used by repository handles.
     *
     * Enables foreign keys, sets a busy timeout, optionally switches to WAL
     * journaling, and selects normal synchronous mode.
     *
     * Params:
     *     db = Open database connection to configure.
     *     options = Repository options controlling WAL mode.
     */
    package static void configure(ref Database db, RepositoryOptions options)
    {
        db.execute("PRAGMA foreign_keys = ON");
        db.execute("PRAGMA busy_timeout = 5000");
        if (options.enableWal)
        {
            string journalMode;
            {
                auto currentJournal = db.execute("PRAGMA journal_mode");
                if (!currentJournal.empty)
                    journalMode = currentJournal.front.peek!string(0).toLower;
            }
            if (journalMode != "wal")
            {
                auto walResult = db.execute("PRAGMA journal_mode = WAL");
                if (!walResult.empty)
                    walResult.front.peek!string(0);
            }
        }
        db.execute("PRAGMA synchronous = NORMAL");
    }

    /** Return the current time for repository database columns.
     *
     * Returns: Timestamp in ISO extended string form.
     */
    package static string currentTimestamp()
    {
        return Clock.currTime.toISOExtString;
    }

    /** Ensure the singleton repository row exists and records `rootPath`.
     *
     * A differing stored root is replaced with `rootPath`; the update is
     * best-effort so read-only databases keep their old value.
     *
     * Params:
     *     db = Open repository database.
     *     rootPath = Root path to store for this repository.
     */
    package static void ensureRepositoryRow(ref Database db, string rootPath)
    {
        auto result = db.execute("SELECT root_path FROM repository WHERE id = 1");
        if (!result.empty)
        {
            auto storedRoot = result.front.peek!string(0);
            if (storedRoot != rootPath)
            {
                /* All catalog paths are relative to this directory. The
                 * stored root is advisory metadata, so a copied, moved, or
                 * sshfs-mounted repository is opened at its current path
                 * instead of being rejected. Keep the old value if the
                 * database happens to be read-only. */
                try
                    db.execute("UPDATE repository SET root_path = ? WHERE id = 1",
                        rootPath);
                catch (Exception)
                {
                }
            }
            return;
        }

        auto now = currentTimestamp();
        db.execute("INSERT INTO repository "
            ~ "(id, root_path, schema_version, created_at, updated_at) "
            ~ "VALUES (1, ?, ?, ?, ?)", rootPath,
            cast(long) currentRepositorySchemaVersion, now, now);
    }

    /** Reject SQLite repositories on filesystems without SQLite guarantees.
     *
     * Params:
     *     rootPath = Repository root directory.
     * Throws: `RepositoryException` when the filesystem type is known to be
     *     unsafe for SQLite locking or durability.
     */
    package static void ensureSupportedFilesystem(string rootPath)
    {
        const fsType = repositoryFilesystemType(rootPath);
        if (fsType.empty || !isUnsupportedRepositoryFilesystemType(fsType))
            return;
        throw new RepositoryException(
            "SQLite repositories are not supported on filesystem type '"
            ~ fsType ~ "': " ~ rootPath
            ~ ". Keep the repository on a local filesystem or use a JSON catalog.");
    }

    /** Move an existing catalog database and its side files into backups.
     *
     * Params:
     *     paths = Repository paths whose database should be preserved.
     *     reason = Short suffix describing why the backup was created.
     * Throws: `Exception` when a file cannot be moved.
     */
    package static string backupExistingCatalog(RepositoryPaths paths, string reason)
    {
        import std.process : thisProcessID;

        if (!exists(paths.databasePath))
            return "";
        mkdirRecurse(paths.backupsPath);
        const stamp = currentTimestamp().replace(":", "-");
        const databaseName = baseName(paths.databasePath);
        const backupPath = buildPath(paths.backupsPath,
            databaseName ~ ".before-" ~ reason ~ "-" ~ stamp ~ "-"
            ~ thisProcessID.to!string);

        /* VACUUM INTO produces a consistent snapshot, including rows that are
         * still only present in the WAL. If the database is too damaged for
         * SQLite, fall back to moving the raw files with sidecars named so
         * SQLite can associate them with the backup database. */
        bool snapshotWritten;
        try
        {
            auto snapshotDb = Database(paths.databasePath);
            scope (exit)
                snapshotDb.close();
            snapshotDb.execute("VACUUM INTO ?", backupPath);
            snapshotWritten = true;
        }
        catch (Exception)
        {
            if (exists(backupPath))
                remove(backupPath);
        }

        if (snapshotWritten)
        {
            foreach (suffix; ["-wal", "-shm"])
            {
                const sideFile = paths.databasePath ~ suffix;
                if (exists(sideFile))
                    remove(sideFile);
            }
            remove(paths.databasePath);
            return backupPath;
        }

        /* Raw fallback: move sidecars first, then the main database last. */
        foreach (suffix; ["-wal", "-shm"])
        {
            const sideFile = paths.databasePath ~ suffix;
            if (exists(sideFile))
                rename(sideFile, backupPath ~ suffix);
        }
        rename(paths.databasePath, backupPath);
        return backupPath;
    }

    /** Throw when this handle has been closed. */
    package void requireOpen() const
    {
        if (!openState)
            throw new RepositoryException("Repository is already closed.");
    }

    /**
     * Initialize or open a repository rooted at `rootPath`.
     *
     * Creates `.dosierskanilo/{logs,exports,backups}` below an existing root.
     *
     * Params:
     *   rootPath = existing directory to use as the repository root.
     *   options = repository/version options.
     *   force = move an existing catalog database and its side files into
     *       `backups/` and create a new empty database.
     * Returns:
     *   An open repository handle.
     * Throws:
     *   `RepositoryException` when the root does not exist, contains an
     *   incompatible repository, or another writer owns the target.
     */
    static Repository initialize(string rootPath,
        RepositoryOptions options = RepositoryOptions(), bool force = false)
    {
        rootPath = canonicalDirectory(rootPath);
        ensureSupportedFilesystem(rootPath);
        auto paths = RepositoryPaths.fromRoot(rootPath);
        mkdirRecurse(paths.metadataPath);
        mkdirRecurse(paths.logsPath);
        mkdirRecurse(paths.exportsPath);
        mkdirRecurse(paths.backupsPath);
        ensureSupportedFilesystem(paths.metadataPath);
        ensureSupportedFilesystem(paths.databasePath);
        TargetWriteLease targetLease;
        if (force)
        {
            targetLease = TargetWriteLease.acquireRepositoryRoot(rootPath);
            if (exists(paths.databasePath))
                backupExistingCatalog(paths, "reinit");
            else
                foreach (suffix; ["-wal", "-shm"])
                {
                    const sideFile = paths.databasePath ~ suffix;
                    if (exists(sideFile))
                        remove(sideFile);
                }
        }
        scope (exit)
        {
            if (targetLease !is null)
                targetLease.release();
        }
        return openRoot(rootPath, options);
    }

    /** Validate a SQLite backup before replacing a repository database.
     *
     * Params:
     *     backupPath = Candidate repository backup file.
     * Throws: `RepositoryException` when the file is missing, corrupt, not a
     *     DosierSkanilo repository, or was written by a newer schema.
     */
    package static void validateRestoreSource(string backupPath)
    {
        if (!exists(backupPath) || !isFile(backupPath))
            throw new RepositoryException("Backup file does not exist: " ~ backupPath);
        try
        {
            auto db = Database(backupPath);
            try
            {
                auto result = db.execute("PRAGMA integrity_check");
                const status = result.empty ? "" : result.front.peek!string(0);
                if (status != "ok")
                    throw new RepositoryException("Backup integrity check failed: "
                        ~ status);

                bool hasRepository;
                bool hasBlobs;
                bool hasFileRefs;
                bool hasDirectories;
                bool hasMigrations;
                foreach (row; db.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"))
                {
                    const name = row.peek!string(0);
                    hasRepository = hasRepository || name == "repository";
                    hasBlobs = hasBlobs || name == "blobs";
                    hasFileRefs = hasFileRefs || name == "file_refs";
                    hasDirectories = hasDirectories || name == "directories";
                    hasMigrations = hasMigrations || name == "schema_migrations";
                }
                if (!hasRepository || !hasBlobs || !hasFileRefs
                    || !hasDirectories || !hasMigrations)
                    throw new RepositoryException(
                        "File is not a DosierSkanilo repository backup: " ~ backupPath);

                auto versionResult = db.execute(
                    "SELECT schema_version FROM repository WHERE id = 1");
                if (versionResult.empty)
                    throw new RepositoryException(
                        "Repository metadata row is missing from backup: " ~ backupPath);
                const schemaVersion = cast(ulong) versionResult.front.peek!long(0);
                auto migrationResult = db.execute(
                    "SELECT max(version) FROM schema_migrations");
                if (migrationResult.empty
                    || migrationResult.front.peek!(Nullable!long)(0).isNull)
                    throw new RepositoryException(
                        "Backup has no schema migration history: " ~ backupPath);
                const migrationVersion = cast(ulong) migrationResult.front
                    .peek!long(0);
                if (migrationVersion != schemaVersion)
                    throw new RepositoryException(
                        "Backup schema version and migration history disagree: "
                        ~ backupPath);
                if (schemaVersion > currentRepositorySchemaVersion)
                    throw new RepositoryException(
                        "Backup schema is newer than this application: "
                        ~ to!string(schemaVersion));
            }
            finally
            {
                db.close();
            }
        }
        catch (RepositoryException ex)
        {
            throw ex;
        }
        catch (Exception ex)
        {
            throw new RepositoryException(
                "Backup could not be opened: " ~ ex.msg);
        }
    }

    /** Replace a repository database with a validated SQLite backup.
     *
     * The current database and its side files are moved into `backups/` when
     * `force` is true. The source is validated before any target change.
     *
     * Params:
     *     rootPath = Repository root directory.
     *     backupPath = SQLite database file produced by `backupTo`.
     *     force = Replace an existing database. Required when one exists.
     * Returns: A newly opened repository handle.
     * Throws: `RepositoryException` when the backup is invalid, an existing
     *     database is present without `force`, or another writer owns the
     *     target.
     */
    static Repository restore(string rootPath, string backupPath, bool force = false)
    {
        import std.uuid : randomUUID;

        rootPath = canonicalDirectory(rootPath);
        ensureSupportedFilesystem(rootPath);
        validateRestoreSource(backupPath);
        auto paths = RepositoryPaths.fromRoot(rootPath);
        ensureSupportedFilesystem(paths.metadataPath);
        ensureSupportedFilesystem(paths.databasePath);
        if (buildNormalizedPath(absolutePath(backupPath)) == paths.databasePath)
            throw new RepositoryException(
                "Restore source must differ from the repository database.");

        mkdirRecurse(paths.metadataPath);
        mkdirRecurse(paths.logsPath);
        mkdirRecurse(paths.exportsPath);
        mkdirRecurse(paths.backupsPath);

        auto targetLease = TargetWriteLease.acquireRepositoryRoot(rootPath);
        scope (exit)
            targetLease.release();

        /* Prepare and validate the replacement before the live database is
         * touched. Older backups are migrated in the staged copy. */
        const staging = paths.databasePath ~ ".restore-"
            ~ randomUUID().toString() ~ ".tmp";
        scope (failure)
            if (exists(staging))
                remove(staging);
        copy(backupPath, staging);
        try
        {
            auto stagedDb = Database(staging);
            try
            {
                migrate(stagedDb, currentTimestamp());
                validateStagedRestore(stagedDb, staging);
            }
            finally
                stagedDb.close();
        }
        catch (Exception failure)
        {
            throw new RepositoryException(
                "Backup cannot be prepared for restore: " ~ failure.msg);
        }

        string safetyBackup;
        if (exists(paths.databasePath))
        {
            if (!force)
                throw new RepositoryException(
                    "Repository already has a database. Use --force to replace it.");
            safetyBackup = backupExistingCatalog(paths, "restore");
        }
        foreach (suffix; ["-wal", "-shm"])
        {
            const sideFile = paths.databasePath ~ suffix;
            if (exists(sideFile))
                remove(sideFile);
        }

        try
        {
            rename(staging, paths.databasePath);
            auto restored = openRoot(rootPath, RepositoryOptions());
            restored.appendLog("repository.restore", backupPath);
            return restored;
        }
        catch (Exception failure)
        {
            /* Put the safety snapshot back so a failed reopen does not remove
             * the previously working catalog. */
            try
            {
                if (exists(paths.databasePath))
                    remove(paths.databasePath);
                foreach (suffix; ["-wal", "-shm"])
                {
                    const sideFile = paths.databasePath ~ suffix;
                    if (exists(sideFile))
                        remove(sideFile);
                }
                if (safetyBackup.length > 0 && exists(safetyBackup))
                {
                    rename(safetyBackup, paths.databasePath);
                    foreach (suffix; ["-wal", "-shm"])
                        if (exists(safetyBackup ~ suffix))
                            rename(safetyBackup ~ suffix,
                                paths.databasePath ~ suffix);
                }
            }
            catch (Exception)
            {
            }
            throw failure;
        }
    }

    /** Validate a staged restore database after migration.
     *
     * Params:
     *     db = Open staged database.
     *     stagingPath = Staged path used in diagnostics.
     * Throws: `RepositoryException` when required tables or the generated
     *     virtual-reference column are missing.
     */
    package static void validateStagedRestore(ref Database db, string stagingPath)
    {
        bool hasVirtualColumn;
        foreach (row; db.execute("PRAGMA table_xinfo(file_refs)"))
            if (row.peek!string(1) == "is_virtual")
                hasVirtualColumn = true;
        if (!hasVirtualColumn)
            throw new RepositoryException(
                "Restored database has no virtual-reference column: "
                ~ stagingPath);

        bool[string] tables;
        foreach (row; db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"))
            tables[row.peek!string(0)] = true;
        foreach (required; ["repository", "blobs", "file_refs", "directories",
            "metadata_status", "media_signatures", "torrent_info",
            "schema_migrations"])
            if (required !in tables)
                throw new RepositoryException(
                    "Restored database is missing table '" ~ required ~ "': "
                    ~ stagingPath);
    }

    /** Open the repository containing `startPath`.
     *
     * Params:
     *     startPath = Directory or file path used to locate the nearest
     *         repository root.
     *     options = Database and schema options.
     * Returns: An open repository handle.
     * Throws: `RepositoryException` when no repository root is found or the
     *     starting path does not exist.
     */
    static Repository open(string startPath, RepositoryOptions options = RepositoryOptions())
    {
        auto rootPath = findRoot(startPath);
        if (rootPath.empty)
            throw new RepositoryException("No .dosierskanilo repository found from: "
                ~ startPath);
        return openRoot(rootPath, options);
    }

    /** Find the nearest repository root or return an empty string.
     *
     * Params:
     *     startPath = Directory or file path to start searching from.
     * Returns: The canonical repository root, or an empty string when no
     *     `.dosierskanilo` directory exists on the path to the filesystem root.
     * Throws: `RepositoryException` when `startPath` does not exist.
     */
    static string findRoot(string startPath)
    {
        if (startPath.empty)
            return "";

        auto current = canonicalDirectory(startPath);
        while (true)
        {
            auto metadataPath = buildPath(current, repositoryDirectoryName);
            if (exists(metadataPath) && isDir(metadataPath))
                return current;

            const auto parent = buildNormalizedPath(dirName(current));
            if (parent == current)
                return "";
            current = parent;
        }
    }

    /** Return the canonical repository root.
     *
     * Returns: Absolute path of the repository root.
     */
    @property string rootPath()
    {
        requireOpen();
        return repositoryPaths.rootPath;
    }

    /** Return the SQLite database path.
     *
     * Returns: Path of the repository's SQLite catalog file.
     */
    @property string databasePath()
    {
        requireOpen();
        return repositoryPaths.databasePath;
    }

    /** Return the structured repository operation log path.
     *
     * Returns: Path of the JSON-lines operation log.
     */
    @property string logFilePath()
    {
        requireOpen();
        return repositoryPaths.logFilePath;
    }

    /** Append one structured operation record to the repository log.
     *
     * Params:
     *     eventName = Short event identifier stored in the `event` field.
     *     message = Detail text stored in the `message` field.
     */
    void appendLog(string eventName, string message)
    {
        requireOpen();
        auto file = File(repositoryPaths.logFilePath, "a");
        file.writeln("{\"timestamp\":\"", currentTimestamp(),
            "\",\"event\":\"", escapeLogValue(eventName),
            "\",\"message\":\"", escapeLogValue(message), "\"}");
    }

    /** Write a consistent database snapshot to the backup directory.
     *
     * The backup name combines a second-resolution timestamp, the process ID,
     * and a per-process serial so repeated backups do not collide. The created
     * path is appended to the operation log.
     */
    package void backupDatabase()
    {
        import core.atomic : atomicFetchAdd;
        import std.process : thisProcessID;
        import std.string : replace;

        /* Second-resolution stamps collide on repeated imports within one
         * second; disambiguate with the process id and a per-process serial. */
        __gshared size_t backupSerial;
        auto serial = atomicFetchAdd(backupSerial, 1) + 1;
        auto stamp = currentTimestamp().replace(":", "-");
        auto backupPath = buildPath(repositoryPaths.backupsPath,
            "catalog-" ~ stamp ~ "-" ~ thisProcessID.to!string ~ "-"
                ~ serial.to!string ~ ".sqlite3");
        /* VACUUM INTO produces a consistent snapshot, including rows that
         * still live in the WAL, instead of copying a live database file. */
        database.execute("VACUUM INTO ?", backupPath);
        appendLog("repository.backup", backupPath);
    }

    /** Return repository metadata.
     *
     * Returns: The repository's stored root, schema version, and timestamps.
     * Throws: `RepositoryException` when the repository metadata row is
     *     missing.
     */
    RepositoryInfo info()
    {
        requireOpen();
        auto result = database.execute("SELECT root_path, schema_version, "
            ~ "created_at, updated_at, media_info_version, "
            ~ "file_utility_version FROM repository WHERE id = 1");
        if (result.empty)
            throw new RepositoryException("Repository metadata row is missing.");

        auto row = result.front;
        return RepositoryInfo(
            row.peek!string(0),
            cast(ulong) row.peek!long(1),
            row.peek!string(2),
            row.peek!string(3),
            row.peek!(Nullable!string)(4).isNull
                ? "" : row.peek!(Nullable!string)(4).get,
            row.peek!(Nullable!string)(5).isNull
                ? "" : row.peek!(Nullable!string)(5).get);
    }

    /** Return aggregate counters and storage facts for this repository.
     *
     * The counters are read in one aggregate statement. File sizes describe
     * the live database and its side files; the backup count includes every
     * regular file below the repository backup directory.
     *
     * Returns: The current repository status.
     * Throws: `RepositoryException` when the repository metadata row is
     *     missing.
     */
    CatalogStatus catalogStatus()
    {
        requireOpen();
        auto result = CatalogStatus();
        const repositoryInfo = info();
        result.storageMode = OperationStorageMode.repository;
        result.sourcePath = repositoryInfo.rootPath;
        result.databasePath = repositoryPaths.databasePath;
        result.schemaVersion = repositoryInfo.schemaVersion;
        result.createdAt = repositoryInfo.createdAt;
        result.updatedAt = repositoryInfo.updatedAt;
        result.mediaInfoVersion = repositoryInfo.mediaInfoVersion;
        result.fileUtilityVersion = repositoryInfo.fileUtilityVersion;
        result.treeStatisticsAvailable = true;

        auto row = database.execute(
            "SELECT "
            ~ "(SELECT count(*) FROM blobs), "
            ~ "(SELECT count(*) FROM file_refs), "
            ~ "(SELECT count(*) FROM file_refs WHERE is_virtual = 0), "
            ~ "(SELECT count(*) FROM file_refs WHERE is_virtual = 1), "
            ~ "(SELECT count(*) FROM directories), "
            ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
            ~ "JOIN blobs b ON b.id = f.blob_id WHERE f.is_virtual = 0), 0), "
            ~ "(SELECT count(*) FROM file_refs WHERE exists_on_disk = 0 "
            ~ "AND is_virtual = 0), "
            ~ "(SELECT count(*) FROM blobs WHERE md5 IS NOT NULL "
            ~ "AND sha1 IS NOT NULL AND xxh64 IS NOT NULL), "
            ~ "(SELECT count(*) FROM blobs WHERE file_type IS NOT NULL "
            ~ "AND length(file_type) > 0), "
            ~ "(SELECT count(*) FROM media_signatures), "
            ~ "(SELECT count(*) FROM metadata_status WHERE metadata_kind = "
            ~ "'archives' AND state IN ('completed', 'empty')), "
            ~ "(SELECT count(*) FROM torrent_info), "
            ~ "(SELECT count(*) FROM (SELECT 1 FROM blobs b "
            ~ "WHERE b.md5 IS NOT NULL AND b.sha1 IS NOT NULL "
            ~ "AND b.xxh64 IS NOT NULL AND EXISTS (SELECT 1 FROM file_refs f "
            ~ "WHERE f.blob_id = b.id) GROUP BY b.file_size, b.md5, b.sha1, "
            ~ "b.xxh64 HAVING count(*) > 1))").front;
        result.blobCount = cast(size_t) row.peek!long(0);
        result.referenceCount = cast(size_t) row.peek!long(1);
        result.physicalReferenceCount = cast(size_t) row.peek!long(2);
        result.archiveMemberCount = cast(size_t) row.peek!long(3);
        result.directoryCount = cast(size_t) row.peek!long(4);
        result.aggregateSize = cast(ulong) row.peek!long(5);
        result.missingReferenceCount = cast(size_t) row.peek!long(6);
        result.checksumBlobCount = cast(size_t) row.peek!long(7);
        result.fileTypeBlobCount = cast(size_t) row.peek!long(8);
        result.mediaBlobCount = cast(size_t) row.peek!long(9);
        result.archiveBlobCount = cast(size_t) row.peek!long(10);
        result.torrentBlobCount = cast(size_t) row.peek!long(11);
        result.duplicateGroupCount = cast(size_t) row.peek!long(12);

        result.catalogSize = fileSizeOrZero(repositoryPaths.databasePath);
        result.walSize = fileSizeOrZero(repositoryPaths.databasePath ~ "-wal");
        result.sharedMemorySize = fileSizeOrZero(
            repositoryPaths.databasePath ~ "-shm");
        if (exists(repositoryPaths.backupsPath)
            && isDir(repositoryPaths.backupsPath))
            foreach (entry; dirEntries(repositoryPaths.backupsPath,
                SpanMode.shallow))
                if (isFile(entry.name))
                    ++result.backupCount;
        return result;
    }

    /** Return a file size, or zero when the file does not exist.
     *
     * Params:
     *     path = File path to inspect.
     * Returns: Size in bytes, or zero for a missing file.
     */
    package static ulong fileSizeOrZero(string path)
    {
        return exists(path) && isFile(path) ? getSize(path) : 0;
    }

    /** Write a consistent, validated copy of the repository database.
     *
     * Uses SQLite `VACUUM INTO`, which includes rows still present in the WAL
     * and produces a compact snapshot. The destination must not exist.
     *
     * Params:
     *     outputPath = Destination SQLite database file.
     * Throws: `RepositoryException` when the destination exists, equals the
     *     live database, or fails its integrity check; `OperationTargetBusyException`
     *     when another writer owns the repository.
     */
    void backupTo(string outputPath)
    {
        requireOpen();
        const target = buildNormalizedPath(absolutePath(outputPath));
        if (target == repositoryPaths.databasePath)
            throw new RepositoryException(
                "Backup path must differ from the repository database.");
        if (exists(target))
            throw new RepositoryException("Backup target already exists: " ~ target);
        mkdirRecurse(dirName(target));
        ensureSupportedFilesystem(dirName(target));

        auto targetLease = TargetWriteLease.acquireRepositoryRoot(
            repositoryPaths.rootPath);
        scope (exit)
            targetLease.release();

        try
        {
            database.execute("VACUUM INTO ?", target);
            auto verificationDb = Database(target);
            try
            {
                auto result = verificationDb.execute("PRAGMA integrity_check");
                const status = result.empty ? "" : result.front.peek!string(0);
                if (status != "ok")
                    throw new RepositoryException(
                        "Backup integrity check failed: " ~ status);
            }
            finally
            {
                verificationDb.close();
            }
        }
        catch (Exception failure)
        {
            if (exists(target))
                remove(target);
            throw failure;
        }
        appendLog("repository.backup", target);
    }

    /** Explicitly close the repository connection. */
    void close()
    {
        if (openState)
        {
            database.close();
            openState = false;
        }
    }
}

/** Resolve a path to an absolute, normalized directory.
 *
 * When `path` names an existing file, its parent directory is returned.
 *
 * Params:
 *     path = Directory or file path to resolve.
 * Returns: Absolute normalized directory path.
 * Throws: `RepositoryException` when the path does not exist.
 */
package string canonicalDirectory(string path)
{
    auto resolved = buildNormalizedPath(absolutePath(path));
    if (!exists(resolved))
        throw new RepositoryException("Directory does not exist: " ~ path);
    if (!isDir(resolved))
        resolved = dirName(resolved);
    return resolved;
}

/** Escape a value for inclusion in a JSON log line.
 *
 * Params:
 *     value = Raw text to escape.
 * Returns: Text with backslashes, quotes, and control characters escaped.
 */
package string escapeLogValue(string value)
{
    import std.string : replace;
    return value.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t");
}

@("repository initialization and root discovery")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    assert(repository.rootPath == buildNormalizedPath(root));
    assert(repository.info.schemaVersion == currentRepositorySchemaVersion);
    assert(exists(repository.databasePath));
    repository.close();

    auto nested = buildPath(root, "nested", "path");
    mkdirRecurse(nested);
    auto reopened = Repository.open(nested);
    assert(reopened.rootPath == buildNormalizedPath(root));
    const databasePath = reopened.databasePath;
    reopened.close();

    import core.thread : Thread;
    import core.time : msecs;
    import std.file : timeLastModified;
    auto stamp = timeLastModified(databasePath);
    Thread.sleep(20.msecs);
    auto steady = Repository.open(root);
    steady.close();
    assert(timeLastModified(databasePath) == stamp,
        "Opening an initialized repository must not write to the database.");
}

@("repository schema reaches current version on a fresh database")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-schema-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    assert(repository.info.schemaVersion == currentRepositorySchemaVersion,
        "Fresh repository must reach the current schema version.");
    assert(currentRepositorySchemaVersion == 6,
        "Update this test when the schema version changes.");

    // Reopen must keep the schema version stable and must not rewrite the database.
    auto reopened = Repository.open(root);
    scope (exit)
        reopened.close();
    assert(reopened.info.schemaVersion == currentRepositorySchemaVersion);
}

@("repository schema migrates a v1 database to the current version")
unittest
{
    import dosierskanilo.repository.schema : initialSchema;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-v1-migration-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const dbPath = buildPath(root, "catalog.sqlite3");
    auto db = Database(dbPath);

    Repository.configure(db, RepositoryOptions());
    db.run(initialSchema);
    db.execute("INSERT INTO schema_migrations (version, applied_at) "
        ~ "VALUES (1, ?)", Repository.currentTimestamp());
    db.execute("INSERT INTO repository (id, root_path, schema_version, created_at, updated_at) "
        ~ "VALUES (1, ?, 1, ?, ?)", root, Repository.currentTimestamp(),
        Repository.currentTimestamp());

    // Verify the v1 baseline.
    {
        auto result = db.execute(
            "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
        assert(!result.empty);
        assert(cast(ulong) result.front.peek!long(0) == 1,
            "Baseline must be schema version 1");
    }

    // Migrate to the current version.
    migrate(db, Repository.currentTimestamp());

    {
        auto result = db.execute(
            "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
        assert(!result.empty);
        assert(cast(ulong) result.front.peek!long(0)
            == currentRepositorySchemaVersion,
            "v1 database must reach the current schema version");
    }

    db.close();
}
@("repository force reinitialization backs up and clears the catalog")
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse,
        tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-force-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "sample.txt"), "payload");

    auto repository = Repository.initialize(root);
    repository.scan(RepositoryScanOptions(true, false, false));
    assert(repository.blobCount > 0);
    repository.close();

    auto reinitialized = Repository.initialize(root, RepositoryOptions(), true);
    scope (exit)
        reinitialized.close();
    assert(reinitialized.blobCount == 0);

    bool foundBackup;
    foreach (entry; dirEntries(buildPath(root, ".dosierskanilo", "backups"),
        SpanMode.shallow))
    {
        if (entry.name.canFind(".before-reinit-"))
            foundBackup = true;
    }
    assert(foundBackup, "force initialization must preserve the old database");
}

@("repository catalog status reports aggregate counters")
unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-status-"
        ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "sub"));
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "a.txt"), "alpha");
    write(buildPath(root, "sub", "b.txt"), "beta");

    auto repository = Repository.initialize(root);
    scope (exit)
        if (repository !is null)
            repository.close();
    repository.scan(RepositoryScanOptions(true, false, false));
    MetadataScanOptions metadata;
    metadata.calculateChecksums = true;
    repository.updateMetadata(metadata);

    auto status = repository.catalogStatus();
    assert(status.storageMode == OperationStorageMode.repository);
    assert(status.sourcePath == root);
    assert(status.databasePath.endsWith(".sqlite3"));
    assert(status.schemaVersion > 0);
    assert(status.blobCount == 2);
    assert(status.referenceCount == 2);
    assert(status.physicalReferenceCount == 2);
    assert(status.archiveMemberCount == 0);
    assert(status.directoryCount == 1);
    assert(status.aggregateSize == 9);
    assert(status.missingReferenceCount == 0);
    assert(status.checksumBlobCount == 2);
    assert(status.fileTypeBlobCount == 0);
    assert(status.catalogSize > 0);
    assert(status.treeStatisticsAvailable);

    remove(buildPath(root, "sub", "b.txt"));
    repository.scan(RepositoryScanOptions(true, false, false));
    status = repository.catalogStatus();
    assert(status.missingReferenceCount == 1);
}

@("force reinitialization removes stale sidecars without a database")
unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-stale-sidecars-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    auto repository = Repository.initialize(root);
    repository.close();
    const databasePath = buildPath(root, ".dosierskanilo", "catalog.sqlite3");
    remove(databasePath);
    write(databasePath ~ "-wal", "stale wal");
    write(databasePath ~ "-shm", "stale shm");

    auto reinitialized = Repository.initialize(root, RepositoryOptions(), true);
    reinitialized.close();
    assert(!exists(databasePath ~ "-wal"));
    assert(!exists(databasePath ~ "-shm"));
}

@("force reinitialization snapshots uncheckpointed WAL rows")
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : SpanMode, dirEntries, mkdirRecurse, rmdirRecurse,
        tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-wal-backup-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto initial = Repository.initialize(root);
    initial.close();
    const databasePath = buildPath(root, ".dosierskanilo", "catalog.sqlite3");
    auto live = Database(databasePath);
    scope (exit)
        live.close();
    live.execute("PRAGMA journal_mode = WAL");
    live.execute("INSERT INTO blobs (id, file_size) VALUES (1, 5)");
    live.execute("INSERT INTO file_refs "
        ~ "(id, blob_id, relative_path, exists_on_disk) "
        ~ "VALUES (1, 1, 'wal-only.txt', 1)");
    /* Keep the connection open so the committed row stays in the WAL. */
    auto reinitialized = Repository.initialize(root, RepositoryOptions(), true);
    reinitialized.close();

    string backupPath;
    foreach (entry; dirEntries(buildPath(root, ".dosierskanilo", "backups"),
        SpanMode.shallow))
        if (entry.name.canFind(".before-reinit-"))
            backupPath = entry.name;
    assert(backupPath.length > 0, "force init must write a safety snapshot");
    auto backup = Database(backupPath);
    scope (exit)
        backup.close();
    assert(backup.execute("SELECT count(*) FROM file_refs")
        .oneValue!long == 1,
        "the safety snapshot must include committed WAL rows");
}

@("repository backup and restore round-trip")
unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-backup-" ~ randomUUID().toString());
    const backup = buildPath(tempDir(), "repository-backup-" ~ randomUUID().toString()
        ~ ".sqlite3");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(backup))
            remove(backup);
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "first.txt"), "first");

    auto repository = Repository.initialize(root);
    repository.scan(RepositoryScanOptions(true, false, false));
    assert(repository.blobCount == 1);
    repository.backupTo(backup);
    assert(exists(backup));
    repository.close();

    write(buildPath(root, "second.txt"), "second");
    auto changed = Repository.open(root);
    changed.scan(RepositoryScanOptions(true, false, false));
    assert(changed.blobCount == 2);
    changed.close();

    assertThrown!RepositoryException(Repository.restore(root, backup));
    auto restored = Repository.restore(root, backup, true);
    scope (exit)
        restored.close();
    assert(restored.blobCount == 1);

    import std.file : readText;
    const invalid = buildPath(tempDir(), "invalid-backup-" ~ randomUUID().toString());
    write(invalid, "not a sqlite database");
    scope (exit)
        if (exists(invalid))
            remove(invalid);
    assertThrown!RepositoryException(Repository.restore(root, invalid, true));

    /* A foreign database with matching table names but no migration history
     * must be rejected before the live catalog is moved. */
    const foreign = buildPath(tempDir(), "foreign-backup-"
        ~ randomUUID().toString() ~ ".sqlite3");
    scope (exit)
        if (exists(foreign))
            remove(foreign);
    {
        auto foreignDb = Database(foreign);
        foreignDb.execute("CREATE TABLE repository (id INTEGER PRIMARY KEY, "
            ~ "root_path TEXT, schema_version INTEGER, created_at TEXT, "
            ~ "updated_at TEXT)");
        foreignDb.execute("INSERT INTO repository VALUES "
            ~ "(1, '.', 6, '2026-01-01', '2026-01-01')");
        foreignDb.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, "
            ~ "file_size INTEGER)");
        foreignDb.execute("CREATE TABLE file_refs (id INTEGER PRIMARY KEY, "
            ~ "blob_id INTEGER, relative_path TEXT)");
        foreignDb.execute("CREATE TABLE directories (id INTEGER PRIMARY KEY)");
        foreignDb.close();
    }
    assertThrown!RepositoryException(Repository.restore(root, foreign, true));
    auto unchanged = Repository.open(root);
    scope (exit)
        unchanged.close();
    assert(unchanged.blobCount == 1,
        "a rejected restore must leave the live catalog untouched");
}

@("repository opens at a new mount path and rebinds the advisory root")
unittest
{
    import std.file : exists, mkdirRecurse, rename, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "repository-move-"
        ~ randomUUID().toString());
    const moved = buildPath(tempDir(), "repository-moved-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(moved))
            rmdirRecurse(moved);
    }
    write(buildPath(root, "sample.txt"), "payload");

    auto repository = Repository.initialize(root);
    repository.scan(RepositoryScanOptions(true, false, false));
    repository.close();

    rename(root, moved);
    auto reopened = Repository.open(moved);
    scope (exit)
        reopened.close();
    assert(reopened.rootPath == buildNormalizedPath(moved));
    assert(reopened.info.rootPath == buildNormalizedPath(moved),
        "opening at another path must refresh the advisory root");
    assert(reopened.fileReferenceByRelativePath("sample.txt").present,
        "stored references stay valid because they are root-relative");
}
