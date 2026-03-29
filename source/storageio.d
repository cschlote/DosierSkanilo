/** JSON storage read helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module storageio;

import std.exception;
import std.datetime.systime;
import std.file;
import std.path;
import std.uuid;

import dosierskanilo.namedbinaryblob;
import logging;

/** Read scanner data from a JSON storage file.
 *
 * Params:
 *   jsonFile = JSON storage file path.
 *   forceOverwrite = continue with empty DB when deserialize fails.
 *   dynObjectArray = destination object array.
 * Returns:
 *   true on success or intentional empty initialization.
 */
bool readStorageJsonFile(string jsonFile, bool forceOverwrite, ref NamedBinaryBlob[] dynObjectArray)
{
    bool rc = true;
    if (!exists(jsonFile))
    {
        logFLine("Storage file '%s' does not exist. Start with an empty database.", jsonFile);
        dynObjectArray.length = 0;
    }
    else
    {
        try
        {
            dynObjectArray = deserializeDataClassJsonFile(jsonFile);
        }
        catch (Exception ex)
        {
            logFLine("Failed to deserialize storage file '%s'.", jsonFile);
            logLine(ex.msg);

            if (forceOverwrite)
            {
                logLine("Force mode enabled. Continue with an empty database.");
                dynObjectArray.length = 0;
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

/** Generate a backup file name based on the original file name and current timestamp.
 *
 * Params:
 *   originalFile = the original file path to base the backup name on.
 *   extension = the file extension to use for the backup file (e.g., ".json").
 *   nowString = optional timestamp string to use in the backup file name (default: current time in ISO format).
 * Returns:
 *   a new file name in the format "basename-YYYY-MM-DDTHH-MM-SS.extension".
 */
private string getBackupFileName(string originalFile, string extension, string nowString = Clock
        .currTime.toISOExtString())
{
    auto basename = originalFile.baseName(extension);
    return basename ~ "-" ~ nowString ~ extension;
}

/** Make a backup of the original file if it exists.
 *
 * Params:
 *   backupFile = the backup file path to create.
 *   originalFile = the original file path to back up.
 *   mustCopy = if true, attempt to copy the original file to the backup location instead of renaming. This is used when the original file cannot be renamed due to permissions or other issues.
 * Returns:
 *   true on success, false on failure.
 */
private bool makeBackupFile(string backupFile, string originalFile, ref bool mustCopy)
{
    bool rc = true;
    try
    {
        rename(originalFile, backupFile);
        logFLine("Backuped file '%s' to '%s'.", originalFile, backupFile);
    }
    catch (FileException e)
    {
        logLine(
            "Failed to rename existing file for backup. Attempting to copy and delete original.");
        logLine(e.msg);
        try
        {
            copy(originalFile, backupFile);
            remove(originalFile);
            logFLine("Copied existing file '%s' to '%s' and removed original.", originalFile, backupFile);
            mustCopy = true;
        }
        catch (Exception ex)
        {
            logLine("Failed to backup existing file. Aborting write operation to avoid data loss.");
            logLine(ex.msg);
            return false;
        }
    }
    return rc;
}

/** Restore the original file from the backup if possible, or remove the backup if it was copied.
 *
 * Params:
 *   jsonFile = the original file path to restore.
 *   newname = the backup file path to use for restoration or removal.
 *   mustCopy = if true, indicates that the backup was created by copying and should be removed instead of renamed back.
 */
private void restoreOriginalFile(string jsonFile, string newname, bool mustCopy)
{
    if (mustCopy)
    {
        remove(newname);
        logFLine("Removed backup file '%s' due to serialization failure.", newname);
    }
    else
    {
        rename(newname, jsonFile);
        logFLine("Restored file '%s' to '%s'.", newname, jsonFile);
    }
}

@("Unittest for backup and restore 1 - rename")
unittest
{
    import std.process;
    import std.conv : text;
    import std.file : exists, remove, getcwd;
    import std.path : buildPath;

    auto nowString = Clock.currTime.toISOExtString();

    /* Test with local file to trigger rename-based backup and restore. */
    auto localFile = buildPath(getcwd(), "storageio-backup-test1-" ~ nowString ~ ".json");
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
    auto tempFile2 = buildPath(tempDir(), "storageio-backup-test-" ~ nowString ~ ".json");
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

/** Write scanned data to some storage file
 *
 *  Depending on configuration, the data is serialized to some file.
 * Params:
 *   jsonFile = JSON storage file path.
 *   dynObjectArray = source object array.
 *   jsonFileExtension = file extension for backup files (default: ".json").
 *   nowString = optional timestamp string to use in backup file names (default: current time in ISO format).
 * Returns:
 *   true on success, false on failure. On failure, the original file is left unchanged if possible.
 */
bool writeStorageJsonFile(string jsonFile, ref NamedBinaryBlob[] dynObjectArray,
    string jsonFileExtension = ".json",
    string nowString = Clock.currTime.toISOExtString())
{
    string newname = null;
    bool mustCopy = false;
    if (jsonFile.exists)
    {
        newname = getBackupFileName(jsonFile, jsonFileExtension, nowString);
        logFLine("Backed up existing file '%s' to '%s'.", jsonFile, newname);
        auto rc = makeBackupFile(newname, jsonFile, mustCopy);
        if (!rc)
            return false;
    }
    logLine("Serialize Array of Objects");
    try
    {
        serializeDataClassArrayFile(jsonFile, dynObjectArray);
    }
    catch (Exception ex)
    {
        logLine("Something wonderful happened. Can't serialize.");
        logLine(ex);
        if (newname !is null)
            restoreOriginalFile(jsonFile, newname, mustCopy);
        return false;
    }
    return true;
}

@("writeStorageJsonFile")
unittest
{
    import std.process;
    import std.conv : text;

    auto currtime = Clock.currTime();
    auto currtimestr = currtime.toISOExtString();

    auto tempFile = buildPath(tempDir(), "storageio-test-" ~ currtimestr ~ ".json");
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
