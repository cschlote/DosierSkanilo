/** JSON storage helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.service.storageio;

import std.exception;
import std.datetime.systime;
import std.file;
import std.path;
import std.string : replace;
import std.uuid;

import dosierskanilo.logging;
import dosierskanilo.model.namedbinaryblob;

/** Read scanner data from a JSON storage file.
 *
 * Missing files are treated as first-run state. Deserialization errors only
 * abort the load when `forceOverwrite` is false.
 *
 * Params:
 *   jsonFile = JSON storage file path.
 *   forceOverwrite = continue with an empty database when deserialization fails.
 *   dynObjectWrapper = destination wrapper object.
 * Returns:
 *   `true` on success or intentional empty initialization.
 */
bool readStorageJsonFile(string jsonFile, bool forceOverwrite, ref NamedBinaryBlobCatalog dynObjectWrapper)
{
    bool rc = true;
    if (!exists(jsonFile))
    {
        logFLine("Storage file '%s' does not exist. Start with an empty database.", jsonFile);
        dynObjectWrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);
    }
    else
    {
        try
        {
            dynObjectWrapper = deserializeDataClassJsonWrapperFile(jsonFile);
        }
        catch (Exception ex)
        {
            logFLine("Failed to deserialize storage file '%s'.", jsonFile);
            logLine(ex.msg);

            if (forceOverwrite && isCatalogFormatFailure(ex))
            {
                logLine("Force mode enabled. Continue with an empty database.");
                dynObjectWrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);
            }
            else
            {
                logLine(
                    "Aborting read operation to avoid data loss. Use --force to ignore deserialization errors.");
                rc = false;
            }
        }
    }
    return rc;
}

/** Read scanner data from a JSON storage file into an array.
 *
 * This compatibility overload keeps older call sites working while the main
 * application stores the wrapper object directly.
 */
bool readStorageJsonFile(string jsonFile, bool forceOverwrite, ref NamedBinaryBlob[] dynObjectArray)
{
    NamedBinaryBlobCatalog wrapper;
    auto rc = readStorageJsonFile(jsonFile, forceOverwrite, wrapper);
    dynObjectArray = wrapper.dataArray;
    return rc;
}

@("readStorageJsonFile missing file")
unittest
{
    auto missingFile = buildPath(tempDir(), "storageio-missing-" ~ randomUUID().toString() ~ ".json");
    NamedBinaryBlob[] objs = [new NamedBinaryBlob("dummy", 1, Clock.currTime())];

    auto rc = readStorageJsonFile(missingFile, false, objs);
    assert(rc, "Missing storage file should be treated as first run.");
    assert(objs.length == 0, "Database should start empty on first run.");
}

@("readStorageJsonFile malformed json force")
unittest
{
    auto badFile = buildPath(tempDir(), "storageio-bad-" ~ randomUUID().toString() ~ ".json");
    scope (exit)
    {
        if (exists(badFile))
            remove(badFile);
    }

    write(badFile, "{ definitely-not-json }");

    NamedBinaryBlob[] objs = [new NamedBinaryBlob("dummy", 1, Clock.currTime())];
    assert(!readStorageJsonFile(badFile, false, objs),
        "Malformed JSON should fail without --force.");

    objs = [new NamedBinaryBlob("dummy", 1, Clock.currTime())];
    assert(readStorageJsonFile(badFile, true, objs),
        "Malformed JSON should be tolerated with --force.");
    assert(objs.length == 0, "Force mode should reset database to empty.");
}

@("writeStorageJsonFile roundtrip and backup")
unittest
{
    import std.file : exists, readText, remove, getcwd;
    import std.path : buildPath;

    auto stamp = "2000-01-01T00:00:00";
    auto safeStamp = stamp.replace(":", "-");
    auto jsonFile = buildPath(tempDir(), "storageio-write-" ~ safeStamp ~ ".json");
    auto backupFile = buildPath(tempDir(), "storageio-write-" ~ safeStamp ~ "-" ~ safeStamp ~ ".json");
    scope (exit)
    {
        if (exists(jsonFile))
            remove(jsonFile);
        if (exists(backupFile))
            remove(backupFile);
    }

    NamedBinaryBlob[] objs;
    objs ~= new NamedBinaryBlob("test/dummy-text-file.txt", 1234, Clock.currTime());

    assert(writeStorageJsonFile(jsonFile, objs, ".json", stamp));
    assert(exists(jsonFile));
    assert(readText(jsonFile).length > 0);

    assert(writeStorageJsonFile(jsonFile, objs, ".json", stamp));
    assert(exists(backupFile));
    assert(exists(jsonFile));
}

/** Generate a backup file name based on the original file name and current timestamp.
 *
 * The backup name keeps the original basename and appends the timestamp before
 * the extension.
 *
 * Params:
 *   originalFile = the original file path to base the backup name on.
 *   extension = the file extension to use for the backup file (e.g., ".json").
 *   nowString = optional timestamp string to use in the backup file name (default: current time in ISO format).
 * Returns:
 *   a new file name in the format "basename-YYYY-MM-DDTHH-MM-SS.extension".
 */
private string getBackupFileName(string originalFile, string extension,
    string nowString = Clock.currTime.toISOExtString(), string backupDirectory = "")
{
    auto basename = originalFile.baseName(extension);
    auto backupName = basename ~ "-" ~ nowString.replace(":", "-") ~ extension;
    /* Keep backups next to the catalog they belong to, so catalogs with the
     * same base name in different directories cannot collide. */
    return buildPath(backupDirectory.length > 0 ? backupDirectory
        : dirName(originalFile), backupName);
}

/** Make a backup of the original file if it exists.
 *
 * The backup never removes the original from its canonical path: POSIX uses a
 * hard link, and other platforms or filesystems fall back to a copy. This
 * keeps the previous catalog readable if the process dies while the staging
 * file is written.
 *
 * Params:
 *   backupFile = the backup file path to create.
 *   originalFile = the original file path to back up.
 *   mustCopy = set to true when a copy was made instead of a hard link.
 * Returns:
 *   `true` on success, `false` on failure.
 */
private bool makeBackupFile(string backupFile, string originalFile, ref bool mustCopy)
{
    version (Posix)
    {
        import core.sys.posix.unistd : link;
        import std.string : toStringz;

        if (link(toStringz(originalFile), toStringz(backupFile)) == 0)
        {
            mustCopy = false;
            logFLine("Linked backup '%s' to '%s'.", backupFile, originalFile);
            return true;
        }
    }

    try
    {
        copy(originalFile, backupFile);
        mustCopy = true;
        logFLine("Copied existing file '%s' to '%s'.", originalFile, backupFile);
    }
    catch (Exception ex)
    {
        logLine("Failed to backup existing file. Aborting write operation to avoid data loss.");
        logLine(ex.msg);
        return false;
    }
    return true;
}

/** Restore the original file from the backup.
 *
 * This is the counterpart to `makeBackupFile`. A renamed hard-link backup is
 * moved back and consumed; a copy backup is kept, and the canonical file is
 * only recreated when it is missing because copying never removed it.
 *
 * Params:
 *   jsonFile = the original file path to restore.
 *   newname = the backup file path to use for restoration.
 *   mustCopy = true when the backup was created by copying.
 */
private void restoreOriginalFile(string jsonFile, string newname, bool mustCopy)
{
    if (mustCopy)
    {
        /* The canonical file was never removed, so only recreate it when it is
         * missing. Keep the backup on failure so the catalog stays
         * recoverable. */
        try
        {
            if (!exists(jsonFile))
                copy(newname, jsonFile);
            logFLine("Restored file '%s' from backup '%s'.", jsonFile, newname);
        }
        catch (Exception ex)
        {
            logLine("Failed to restore file '%s' from backup '%s'. The backup "
                ~ "was kept.", jsonFile, newname);
            logLine(ex.msg);
        }
    }
    else
    {
        rename(newname, jsonFile);
        logFLine("Restored file '%s' to '%s'.", newname, jsonFile);
    }
}

@("Unittest for backup and restore 1 - hard link")
unittest
{
    import std.process;
    import std.conv : text;
    import std.file : exists, remove, getcwd;
    import std.path : buildPath;

    auto nowString = Clock.currTime.toISOExtString();

    /* Test with local file to trigger hard-link backup and rename restore. */
    auto localFile = buildPath(getcwd(), "storageio-backup-test1-" ~ nowString.replace(":", "-") ~ ".json");
    scope (exit)
    {
        if (exists(localFile))
            remove(localFile);
    }
    auto backupFile = getBackupFileName(localFile, ".json", nowString);
    scope (exit)
    {
        if (exists(backupFile))
            remove(backupFile);
    }
    write(localFile, "{ \"test\": \"data\" }");

    // Test backup creation
    bool mustCopy = false;
    assert(makeBackupFile(backupFile, localFile, mustCopy), "Should create backup file.");
    assert(exists(backupFile), "Backup file should exist after creation.");

    // Test restore from backup
    write(localFile, "{ \"test\": \"data\" }");
    restoreOriginalFile(localFile, backupFile, mustCopy);
    assert(exists(localFile), "Original file should exist after restore.");
}

@("Unittest for backup and restore 2 - copy")
unittest
{
    import std.conv : text;
    import std.file : exists, remove, getcwd;
    import std.path : buildPath;

    auto nowString = Clock.currTime.toISOExtString();

    /* Test with tempDir() path on possibly different filesystem to trigger copy-based backup and restore. */
    auto tempFile2 = buildPath(tempDir(), "storageio-backup-test-" ~ nowString.replace(":", "-") ~ ".json");
    scope (exit)
    {
        if (exists(tempFile2))
            remove(tempFile2);
    }
    auto backupFile2 = getBackupFileName(tempFile2, ".json", nowString);
    scope (exit)
    {
        if (exists(backupFile2))
            remove(backupFile2);
    }
    write(tempFile2, "{ \"test\": \"data\" }");
    // Test backup creation
    bool mustCopy2 = false;
    assert(makeBackupFile(backupFile2, tempFile2, mustCopy2), "Should create backup file.");
    assert(exists(backupFile2), "Backup file should exist after creation.");
    // Test restore from backup
    write(tempFile2, "{ \"test\": \"data\" }");
    restoreOriginalFile(tempFile2, backupFile2, mustCopy2);
    assert(exists(tempFile2), "Original file should exist after restore.");
}

@("Unittest for backup and restore 3 - copy fallback restores, never deletes")
unittest
{
    import std.file : exists, readText, remove, write;
    import std.path : buildPath;

    const auto root = buildPath(tempDir(), "storageio-restore-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    const auto original = buildPath(root, "catalog.json");
    const auto backup = buildPath(root, "catalog-backup.json");
    enum content = "{\"dataVersion\":5,\"dataArray\":[]}";
    write(original, content);
    copy(original, backup);
    remove(original); // state after the copy-based backup

    restoreOriginalFile(original, backup, true);

    assert(exists(original), "Copy fallback must restore the original file.");
    assert(exists(backup), "Backup must be kept as a recovery copy.");
    assert(readText(original) == content);
}

/** Write scanned data to some storage file.
 *
 * The function writes through a backup file first so the original JSON is only
 * replaced after serialization succeeds.
 *
 * Params:
 *   jsonFile = JSON storage file path.
 *   dynObjectWrapper = source wrapper object.
 *   jsonFileExtension = file extension for backup files (default: ".json").
 *   nowString = optional timestamp string to use in backup file names (default: current time in ISO format).
 *   backupDirectory = optional directory for the backup file; empty keeps the
 *     backup next to the catalog.
 *   cancelCheck = optional callback invoked before work starts and after
 *     serialization. A `true` result discards the staging file and leaves the
 *     original catalog unchanged.
 * Returns:
 *   `true` on success, `false` on failure or cancellation. On failure, the original file is left unchanged if possible.
 */
bool writeStorageJsonFile(string jsonFile, ref NamedBinaryBlobCatalog dynObjectWrapper,
    string jsonFileExtension = ".json",
    string nowString = Clock.currTime.toISOExtString(),
    string backupDirectory = "",
    bool delegate() cancelCheck = null)
{
    if (cancelCheck !is null && cancelCheck())
        return false;
    string newname = null;
    bool mustCopy = false;
    if (jsonFile.exists)
    {
        newname = getBackupFileName(jsonFile, jsonFileExtension, nowString,
            backupDirectory);
        logFLine("Backed up existing file '%s' to '%s'.", jsonFile, newname);
        auto rc = makeBackupFile(newname, jsonFile, mustCopy);
        if (!rc)
            return false;
    }
    if (cancelCheck !is null && cancelCheck())
        return false;
    logLine("Serialize Array of Objects");
    /* Serialize into a staging file in the target directory and rename it into
     * place afterwards, so a crash or a full disk cannot leave a truncated
     * catalog at the canonical path. */
    auto stagingFile = jsonFile ~ ".tmp-" ~ randomUUID().toString();
    try
    {
        serializeDataClassWrapperFile(stagingFile, dynObjectWrapper);
        if (cancelCheck !is null && cancelCheck())
        {
            if (exists(stagingFile))
                remove(stagingFile);
            return false;
        }
        /* POSIX rename replaces the target atomically, so a crash can never
         * observe a missing catalog. Windows rename refuses existing targets. */
        version (Windows)
            if (exists(jsonFile))
                remove(jsonFile);
        rename(stagingFile, jsonFile);
    }
    catch (Exception ex)
    {
        logLine("Something wonderful happened. Can't serialize.");
        logLine(ex);
        if (exists(stagingFile))
        {
            try
                remove(stagingFile);
            catch (Exception)
            {
            }
        }
        if (newname !is null)
            restoreOriginalFile(jsonFile, newname, mustCopy);
        return false;
    }
    return true;
}

/** Write scanned data to some storage file from an array.
 *
 * This compatibility overload keeps older call sites working while the main
 * application stores the wrapper object directly.
 */
bool writeStorageJsonFile(string jsonFile, ref NamedBinaryBlob[] dynObjectArray,
    string jsonFileExtension = ".json",
    string nowString = Clock.currTime.toISOExtString(),
    string backupDirectory = "")
{
    NamedBinaryBlobCatalog wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, dynObjectArray);
    return writeStorageJsonFile(jsonFile, wrapper, jsonFileExtension, nowString,
        backupDirectory);
}

@("writeStorageJsonFile")
unittest
{
    import std.process;
    import std.conv : text;

    auto currtime = Clock.currTime();
    auto currtimestr = currtime.toISOExtString();

    auto tempFile = buildPath(tempDir(), "storageio-test-" ~ currtimestr.replace(":", "-") ~ ".json");
    scope (exit)
    {
        if (exists(tempFile))
            remove(tempFile);
    }
    // Create some test data
    NamedBinaryBlob[] objs = [new NamedBinaryBlob("dummy", 1, currtime)];
    assert(objs[0].getFirstFileName == "dummy", "Object name should match.");
    assert(objs[0].fileSpecs.length == 1, "Object size should match.");
    assert(objs[0].getFirstFileModDate == currtimestr, "Object lastModified should match.");

    // Save some data
    assert(writeStorageJsonFile(tempFile, objs, ".json", currtimestr), "Should write storage file.");
    assert(exists(tempFile), "Storage file should exist after writing.");

    // Read back and check content
    auto readObjs = deserializeDataClassJsonFile(tempFile);
    assert(readObjs.length == 1, "Should read back one object.");
    assert(readObjs[0].getFirstFileName == "dummy", "Object name should match.");
    assert(readObjs[0].fileSpecs.length == 1, "Object size should match.");
    assert(readObjs[0].getFirstFileModDate == currtimestr, "Object lastModified should match.");

    // Save some data again, which should trigger backup of the existing file
    auto backupFile = getBackupFileName(tempFile, ".json", currtimestr);
    scope (exit)
    {
        if (exists(backupFile))
            remove(backupFile);
    }
    assert(writeStorageJsonFile(tempFile, objs, ".json", currtimestr), "Should write storage file and create backup.");
    assert(exists(tempFile), "Storage file should exist after writing.");
    assert(exists(backupFile), "Backup file should exist after writing existing file.");

}
