/** Validation rules for SQLite repository CLI commands.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo_cli.repositoryvalidation;

import std.file : exists, isDir, remove, tempDir, write;
import std.path : buildPath;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate repository target, command options, and transfer filenames.
 *
 * The repository path may be defaulted from the legacy scan path or to the
 * current directory, so `options` is updated during validation.
 *
 * Params:
 *     command = Repository subcommand name, for example `"scan"` or `"list"`.
 *     options = Parsed command-line options; repository path fields may be
 *         filled in as a side effect.
 * Returns: `true` when the options are valid, `false` after logging a usage
 *     error otherwise.
 */
bool validateRepositoryOptions(string command, ref ArgsArray options)
{
    if (!options.argJSONFile.empty && command != "import" && command != "export")
    {
        errorLine("--json is available only with scan, analyze, status, import, "
            ~ "or export.");
        return false;
    }
    if (!options.argBaseDir.empty)
    {
        errorLine("--base-dir is available only with JSON scan or analysis.");
        return false;
    }
    if (!options.argExportPath.empty && command != "export")
    {
        errorLine("--path is available only with export.");
        return false;
    }
    if ((!options.argArchiveCacheDir.empty || options.argArchiveCacheMiB != 0)
        && command != "scan" && command != "metadata")
    {
        errorLine("--archive-cache options are available only with scan or metadata.");
        return false;
    }
    if (options.argDryRun)
    {
        errorLine("--dry-run is supported only in JSON mode.");
        return false;
    }
    if (!options.argRestoreInput.empty && command != "restore")
    {
        errorLine("--input is available only with restore.");
        return false;
    }
    if (options.argForce && command != "init" && command != "restore")
    {
        errorLine("--force is available only with init or restore.");
        return false;
    }
    if (!options.argExportJSON.empty && command != "export" && command != "backup")
    {
        errorLine("--output is available only with export or backup.");
        return false;
    }
    if (options.argMergeDuplicates && command != "scan")
    {
        errorLine("--merge-duplicates is available only with scan.");
        return false;
    }
    if (command == "status")
    {
        if (!options.argExportJSON.empty || !options.argImportJSON.empty
            || options.argInitRepository || options.argShowInfo
            || options.argList || options.argDuplicates
            || options.argDropMissing || options.argMergeDuplicates
            || options.argDryRun || options.argRecursive
            || options.argPickHidden || options.argDoChecksums
            || options.argDoFileTypes || options.argDoMediaSig
            || options.argScanArchives || options.argScanTorrents
            || options.argRescanMediaSig || options.argNumberOfThreads != 1
            || options.argPrettyJSON || !options.argQueryText.empty
            || options.argQueryLimit != 50 || options.argQueryOffset != 0
            || options.argQueryVideo || options.argQueryAudio
            || options.argQueryImage || options.argQueryTextStream
            || options.argQueryFileType || options.argQueryArchive
            || options.argQueryTorrent || options.argDuplicateLimit != 100
            || !options.argExportPath.empty
            || (options.argOutputFormat != "table"
                && options.argOutputFormat != "json"))
        {
            errorLine("Status supports only --format and --verbose.");
            return false;
        }
    }
    if (options.argRepositoryPath.empty)
        options.argRepositoryPath = options.argScanPath;
    if (options.argRepositoryPath.empty)
        options.argRepositoryPath = ".";

    if (command == "init" && (!exists(options.argRepositoryPath)
        || !isDir(options.argRepositoryPath)))
    {
        errorFLine("Repository path '%s' is not an existing directory.",
            options.argRepositoryPath);
        return false;
    }
    if (command == "metadata" && !hasMetadataOptions(options))
    {
        errorLine("Metadata command needs at least one metadata option: "
            ~ "--checksums, --file-types, --media-info, --scan-archives, "
            ~ "or --scan-torrents.");
        return false;
    }
    if (command == "import" && options.argImportJSON.empty)
    {
        errorLine("Import requires a JSON catalog filename.");
        return false;
    }
    if (command == "export" && options.argExportJSON.empty)
    {
        errorLine("Export requires an output JSON filename.");
        return false;
    }
    if (command == "restore" && options.argRestoreInput.empty)
    {
        errorLine("Restore requires an input SQLite backup filename.");
        return false;
    }
    if ((command == "info" || command == "list" || command == "duplicates")
        && options.argOutputFormat != "table"
        && options.argOutputFormat != "json")
    {
        errorLine("Repository query format must be 'table' or 'json'.");
        return false;
    }
    if (command == "duplicates" && options.argDuplicateLimit == 0)
    {
        errorLine("--duplicate-limit must be greater than zero.");
        return false;
    }
    if (!validateRepositoryCommand(command, options))
        return false;
    if (!options.argImportJSON.empty && !options.argImportJSON.endsWith(jsonFileExtension))
    {
        errorFLine("Import JSON filename '%s' looks invalid.", options.argImportJSON);
        return false;
    }
    if (command == "export" && !options.argExportJSON.empty
        && !options.argExportJSON.endsWith(jsonFileExtension))
    {
        errorFLine("Export JSON filename '%s' looks invalid.", options.argExportJSON);
        return false;
    }
    return true;
}

@("validateRepositoryOptions")
unittest
{
    auto baseDir = tempDir();

    auto infoOptions = ArgsArray();
    assert(validateRepositoryOptions("info", infoOptions));
    assert(infoOptions.argRepositoryPath == ".");

    auto statusOptions = ArgsArray();
    statusOptions.argOutputFormat = "json";
    assert(validateRepositoryOptions("status", statusOptions));
    assert(statusOptions.argRepositoryPath == ".");

    auto invalidStatus = ArgsArray();
    invalidStatus.argQueryText = "needle";
    assert(!validateRepositoryOptions("status", invalidStatus));

    auto invalidStatusMetadata = ArgsArray();
    invalidStatusMetadata.argDoChecksums = true;
    assert(!validateRepositoryOptions("status", invalidStatusMetadata));

    auto importOptions = ArgsArray();
    importOptions.argImportJSON = buildPath(baseDir, "catalog.json");
    write(importOptions.argImportJSON, "[]");
    scope (exit)
        if (exists(importOptions.argImportJSON))
            remove(importOptions.argImportJSON);
    assert(validateRepositoryOptions("import", importOptions));

    auto invalidMetadata = ArgsArray();
    assert(!validateRepositoryOptions("metadata", invalidMetadata));

    auto invalidExport = ArgsArray();
    invalidExport.argExportJSON = buildPath(baseDir, "catalog.txt");
    assert(!validateRepositoryOptions("export", invalidExport));

    auto selectedExport = ArgsArray();
    selectedExport.argExportJSON = buildPath(baseDir, "catalog.json");
    selectedExport.argExportPath = "archives/sample.zip!/payload/copy.txt";
    assert(validateRepositoryOptions("export", selectedExport));

    auto invalidSelectedList = ArgsArray();
    invalidSelectedList.argExportPath = "archives";
    assert(!validateRepositoryOptions("list", invalidSelectedList));

    auto cachedScan = ArgsArray();
    cachedScan.argArchiveCacheDir = buildPath(baseDir, "cache");
    cachedScan.argArchiveCacheMiB = 64;
    assert(validateRepositoryOptions("scan", cachedScan));

    auto metadataAnalyze = ArgsArray();
    metadataAnalyze.argRunAnalysis = true;
    metadataAnalyze.argDoChecksums = true;
    assert(validateRepositoryOptions("analyze", metadataAnalyze));

    auto invalidCachedList = ArgsArray();
    invalidCachedList.argArchiveCacheMiB = 64;
    assert(!validateRepositoryOptions("list", invalidCachedList));

    auto backupOptions = ArgsArray();
    backupOptions.argExportJSON = buildPath(baseDir, "catalog.sqlite3");
    assert(validateRepositoryOptions("backup", backupOptions));

    auto restoreOptions = ArgsArray();
    restoreOptions.argRestoreInput = buildPath(baseDir, "catalog.sqlite3");
    restoreOptions.argForce = true;
    assert(validateRepositoryOptions("restore", restoreOptions));

    auto missingRestore = ArgsArray();
    assert(!validateRepositoryOptions("restore", missingRestore));

    auto invalidBackupForce = ArgsArray();
    invalidBackupForce.argForce = true;
    assert(!validateRepositoryOptions("backup", invalidBackupForce));
}

/** Whether any list/query filter differs from its default value.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: `true` when query text, offset, limit, media filters or type filters
 *     were supplied.
 */
private bool hasRepositoryListFilters(ArgsArray options)
{
    return !options.argQueryText.empty || options.argQueryOffset != 0
        || options.argQueryLimit != 50 || options.argQueryVideo
        || options.argQueryAudio || options.argQueryImage
        || options.argQueryTextStream || options.argQueryFileType
        || options.argQueryArchive || options.argQueryTorrent;
}

/** Whether any query-oriented option differs from its default.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: `true` when list filters, a non-default duplicate limit or a
 *     non-default output format were supplied.
 */
private bool hasRepositoryQueryOptions(ArgsArray options)
{
    return hasRepositoryListFilters(options) || options.argDuplicateLimit != 100
        || options.argOutputFormat != "table";
}

/** Whether any metadata-enrichment option was requested.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: `true` when checksums, file types, media info, archive scanning or
 *     torrent scanning was requested.
 */
private bool hasMetadataOptions(ArgsArray options)
{
    return options.argDoChecksums || options.argDoFileTypes
        || options.argDoMediaSig || options.argScanArchives
        || options.argScanTorrents;
}

/** Validate that the options are allowed for a repository subcommand.
 *
 * Each subcommand accepts a specific subset of storage and metadata actions;
 * combining an unsupported option with a command reports a usage error.
 *
 * Params:
 *     command = Repository subcommand name such as `"scan"` or `"export"`; an
 *         empty string is accepted without further checks.
 *     options = Parsed command-line options to validate.
 * Returns: `true` when the option combination is valid, `false` after logging a
 *     usage error otherwise.
 */
private bool validateRepositoryCommand(string command, ArgsArray options)
{
    bool hasStorageAction = options.argInitRepository || options.argScanFiles
        || options.argRunMetadata || options.argRunAnalysis
        || !options.argImportJSON.empty || !options.argExportJSON.empty
        || !options.argRestoreInput.empty || options.argWriteJSON;
    bool hasMetadataAction = options.argDoChecksums || options.argDoFileTypes
        || options.argDoMediaSig || options.argScanArchives
        || options.argScanTorrents;

    final switch (command)
    {
    case "info":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog || hasRepositoryListFilters(options)
            || options.argDuplicateLimit != 100)
            return invalidCommandOptions(command);
        break;
    case "status":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog || hasRepositoryListFilters(options)
            || options.argRecursive || options.argPickHidden
            || !options.argRestoreFrom.empty
            || options.argDuplicateLimit != 100
            || (options.argOutputFormat != "table"
                && options.argOutputFormat != "json"))
            return invalidCommandOptions(command);
        break;
    case "list":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog || options.argDuplicateLimit != 100)
            return invalidCommandOptions(command);
        break;
    case "duplicates":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog || hasRepositoryListFilters(options))
            return invalidCommandOptions(command);
        break;
    case "metadata":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunAnalysis || !options.argImportJSON.empty
            || !options.argExportJSON.empty || options.argWriteJSON
            || options.argDropMissing || options.argReplaceCatalog
            || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "analyze", "analyse":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata
            || !options.argImportJSON.empty || !options.argExportJSON.empty
            || options.argWriteJSON || options.argReplaceCatalog
            || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "init":
        if (options.argScanFiles || options.argRunMetadata
            || options.argRunAnalysis || !options.argImportJSON.empty
            || !options.argExportJSON.empty || options.argWriteJSON
            || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "scan":
        if (options.argInitRepository || options.argRunMetadata
            || options.argRunAnalysis || !options.argImportJSON.empty
            || !options.argExportJSON.empty || options.argWriteJSON
            || options.argReplaceCatalog || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "import":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || hasMetadataAction || options.argDropMissing || options.argWriteJSON
            || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "export":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || hasMetadataAction || options.argDropMissing || options.argWriteJSON
            || options.argReplaceCatalog || options.argForce
            || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "backup":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || !options.argImportJSON.empty || options.argWriteJSON
            || options.argDropMissing || options.argReplaceCatalog
            || !options.argRestoreInput.empty || options.argForce
            || hasMetadataAction || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "restore":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || !options.argImportJSON.empty || !options.argExportJSON.empty
            || options.argWriteJSON || options.argDropMissing
            || options.argReplaceCatalog || hasMetadataAction
            || hasRepositoryQueryOptions(options))
            return invalidCommandOptions(command);
        break;
    case "":
        break;
    }
    return true;
}

/** Log the standard usage error for options that a command does not accept.
 *
 * Params:
 *     command = Repository subcommand that received the invalid options.
 * Returns: Always `false`, so callers can `return invalidCommandOptions(...)`.
 */
private bool invalidCommandOptions(string command)
{
    errorFLine("Options are not valid for the '%s' command.", command);
    errorLine("Use --help to see the options supported by this command.");
    return false;
}
