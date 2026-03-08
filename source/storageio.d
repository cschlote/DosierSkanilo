/** JSON storage read helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
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
    if (!exists(jsonFile))
    {
        logFLine("Storage file '%s' does not exist. Start with an empty database.", jsonFile);
        dynObjectArray.length = 0;
        return true;
    }

    try
    {
        dynObjectArray = deserializeDataClassJsonFile(jsonFile);
        return true;
    }
    catch (Exception ex)
    {
        logFLine("Failed to deserialize storage file '%s'.", jsonFile);
        logLine(ex.msg);

        if (forceOverwrite)
        {
            logLine("Force mode enabled. Continue with an empty database.");
            dynObjectArray.length = 0;
            return true;
        }
    }

    return false;
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

/** Write scanned data to some storage file
 *
 *  Depending on configuration, the data is serialized to some file.
 * @param jsonFile = JSON storage file path.
 * @param dynObjectArray = source object array.
 * @param jsonFileExtension = file extension for backup files (default: ".json").
 * @return true on success, false on failure. On failure, the original file is left unchanged if possible.
 */
bool writeStorageJsonFile(string jsonFile, ref NamedBinaryBlob[] dynObjectArray, string jsonFileExtension = ".json")
{
    string newname = null;
    if (jsonFile.exists)
    {
        auto basename = jsonFile.baseName(jsonFileExtension);
        auto nowString = Clock.currTime.toISOExtString();
        newname = basename ~ "-" ~ nowString ~ jsonFileExtension;
        rename(jsonFile, newname);
        logFLine("Backed up existing file '%s' to '%s'.", jsonFile, newname);
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
        {
            rename(newname, jsonFile);
            logFLine("Restored file '%s' to '%s'.", newname, jsonFile);
        }
        return false;
    }
    return true;
}
