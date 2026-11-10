/** Command-line parsing and progress output helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo_cli.parser;

import std.conv;
import std.exception;
import std.getopt;
import std.file;
import std.algorithm.searching : canFind;
import searching = std.algorithm.searching;
import std.format : format;
import std.path;
import std.process;
import std.range;

import core.thread : Thread;
import core.atomic : atomicLoad;
import core.sync.mutex : Mutex;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;
import dosierskanilo_cli.jsonvalidation : validateJsonOptions;
import dosierskanilo_cli.repositoryvalidation : validateRepositoryOptions;
import core.internal.lifetime;
version (Posix)
{
    import core.sys.posix.sys.ioctl : ioctl, TIOCGWINSZ, winsize;
    import core.sys.posix.unistd : STDOUT_FILENO;
}

/** Full usage text printed for `--help`, describing commands and options. */
immutable string helpText = q"EOS

Usage:
    dosierskanilo <command> [ROOT] [options]
    dosierskanilo scan [ROOT] --json CATALOG.json [--base-dir DIR] [options]
    dosierskanilo analyze [ROOT] --json CATALOG.json [--base-dir DIR] [options]

This is a small utility to scan a directory and collect all files
found within. Each file with same size and same checksums are considered
the be the same.

It also utilizes the 'file' utility to determine filetypes, and can
calculate media signatures for audio and video files.

It stores results in JSON v5 catalogs, reads older JSON v0-v4 catalogs, and
analyzes duplicate content and missing references.

The catalog mode stores the current state in a `.dosierskanilo` SQLite
catalog and keeps JSON available for import and export.

Commands:

    init       Initialize a catalog; --force reinitializes an existing database
    scan       Scan a catalog
    metadata   Extract metadata in a catalog
    analyze    Analyze a catalog
    info       Show catalog information
    status     Show aggregate catalog status and statistics
    list       List catalog content references, including virtual members
    duplicates List duplicate blob groups
    import     Import JSON v0-v5 into a catalog
    export     Export a catalog as JSON v5
    backup     Create a consistent SQLite repository backup
    restore    Restore a SQLite repository backup
    recover    List backups/recovery files and optionally restore one

JSON target options:

    --json CATALOG.json   Use the JSON catalog backend
    --base-dir DIR        Base directory for JSON paths (defaults to `.`)

Metadata options (at least one is required for `metadata`):

    --checksums --file-types --media-info --scan-archives --scan-torrents
    --all enables the standard set: checksums, file types, media info, one
    archive scan, and torrent scanning. Repeating --scan-archives still
    selects a deep archive scan.
    --rescan-media-info forces media metadata extraction again

Archive member cache options (scan and metadata):

    --archive-cache-dir DIR   Root directory for extraction sessions
    --archive-cache-size MiB  Maximum cached member bytes (default 1024)

JSON output:

    --pretty                  Indent saved JSON catalogs for human reading
                              (scan, analyze, and export only)

Global options:

    --no-input                Suppress interactive prompts and read no input

Repository maintenance options:

    --force                   Reinitialize an existing repository (init) or
                              replace it during restore
    --output FILE             Output file for JSON export or SQLite backup
    --input FILE              SQLite backup file for restore

Recovery options:

    --restore-from FILE       Copy FILE over the catalog after validation

Option scope keys use the fixed columns `S A M I L D R G J` (`-` means not
available for that scope):

    S Scan (repository or JSON)      A Analyze (repository or JSON)
    M Metadata extraction            I Catalog info/status
    L List catalog content           D Duplicate groups
    R Init/import/export/backup/restore  G Global options
    J JSON catalog workflows

For example, `SA-------` applies to scan and analysis; `---ILD---` applies to
info, list, and duplicate queries.

`analyze --json CATALOG.json` finds and merges duplicate records with complete
checksums. Add `--merge-duplicates` to a JSON scan to analyze and merge directly;
`--dry-run` reports the result without writing the JSON catalog.

Examples:

    dosierskanilo metadata /data/library --checksums --file-types
    dosierskanilo metadata /data/library --all
    dosierskanilo metadata --checksums --file-types --media-info --scan-archives --scan-torrents --verbose
    dosierskanilo scan /data/library --recursive --all
    dosierskanilo analyze /data/library --all
    dosierskanilo scan --json CATALOG.json --checksums --merge-duplicates --dry-run
    dosierskanilo analyze --json CATALOG.json --dry-run
    dosierskanilo status /data/library --format=json
    dosierskanilo status --json CATALOG.json --base-dir /data/library

EOS";

/** Top-level action selected by the command-line parser. */
enum CliCommand
{
    /// No command was recognized; the parser falls back to help output.
    noCommand,
    /// Initialize or open a `.dosierskanilo` repository.
    init,
    /// Scan a repository or JSON catalog for files.
    scan,
    /// Extract checksums, file types, media info, archive and torrent metadata.
    metadata,
    /// Analyze missing file references and duplicate blobs.
    analyze,
    /// Show repository or catalog information.
    info,
    /// Show aggregate catalog status and statistics.
    status,
    /// List catalog content references, including archive and torrent members.
    list,
    /// List groups of blobs with duplicate content.
    duplicates,
    /// Import a JSON catalog into the repository.
    importJson,
    /// Export a repository catalog as JSON.
    exportJson,
    /// Create a consistent SQLite repository backup.
    backup,
    /// Restore a SQLite repository backup.
    restore,
    /// List recovery backups and optionally restore one.
    recover
}

/** Result state of command-line parsing. */
enum ParseStatus
{
    /// Parsing succeeded; the selected command should run.
    run,
    /// Help text should be printed instead of running a command.
    help,
    /// Version information should be printed instead of running a command.
    showVersion,
    /// Parsing failed; diagnostics have already been reported.
    error
}

/** Parsed command-line state passed from the CLI entry point to its handlers. */
struct ParsedCommandLine
{
    /// Outcome of parsing, indicating whether a command may run.
    ParseStatus status;
    /// Selected top-level action.
    CliCommand command;
    /// Parsed option values for the selected command.
    ArgsArray options;
}

/** Parse command-line arguments into a typed command result.
 *
 * This validates the scan path and JSON output file before the rest of the
 * application starts.
 *
 * Params:
 *   args = raw command-line arguments
 * Returns:
 *   Parsed command state and validation status.
 */
ParsedCommandLine parseCommandLine(string[] args)
{
    string command;
    size_t commandIndex;
    ArgsArray argsarray;
    if (args.length > 1)
    {
        switch (args[1])
        {
            case "init", "scan", "metadata", "analyze", "info", "status",
                "list", "duplicates", "import", "export", "backup", "restore",
                "recover":
                command = args[1];
                commandIndex = 1;
                break;
            default:
                break;
        }
    }
    if (args.length <= 1)
        args ~= "--help"; // Show help, if no args given.

    string rootArgument;
    string catalogArgument;
    size_t positionalCount;
    auto positionalStart = commandIndex + 1;
    if (!command.empty && args.length > positionalStart
        && !searching.startsWith(args[positionalStart], "-"))
    {
        if (command == "export")
        {
            rootArgument = args[positionalStart];
            positionalCount = 1;
        }
        else if (command == "import")
        {
            catalogArgument = args[positionalStart];
            positionalCount = 1;
            if (args.length > positionalStart + 1
                && !searching.startsWith(args[positionalStart + 1], "-"))
            {
                rootArgument = catalogArgument;
                catalogArgument = args[positionalStart + 1];
                positionalCount = 2;
            }
        }
        else
        {
            rootArgument = args[positionalStart];
            positionalCount = 1;
        }
    }
    if (!command.empty)
        args = args[0 .. 1] ~ args[commandIndex + 1 + positionalCount .. $];
    if (!catalogArgument.empty)
        argsarray.argJSONFile = catalogArgument;

    /* Parse the commandline with std.getopt */
    GetoptResult helpInformation;
    try
    {
        helpInformation = getopt(args, /* std.getopt.config.required, */

            "output", "------R-- Output JSON file for export or SQLite backup", &argsarray.argExportJSON,
            "input", "------R-- SQLite backup file for restore", &argsarray.argRestoreInput,
            "path", "------R-- Export only the selected path prefix", &argsarray.argExportPath,
            "json", "SA-IL-D-J JSON catalog to read/write", &argsarray.argJSONFile,
            "base-dir", "SA-IL-D-J Base directory for JSON paths", &argsarray.argBaseDir,
            "recursive", "S-------- Recursively scan directories", &argsarray.argRecursive,
            "checksums", "SAM------ Calculate the checksums", &argsarray.argDoChecksums,
            "file-types", "SAM------ Query file type with 'file' utility", &argsarray.argDoFileTypes,
            "media-info", "SAM------ Calculate the media signature", &argsarray.argDoMediaSig,
            "rescan-media-info", "SAM------ Rescan all files for media signature", &argsarray.argRescanMediaSig,
            "scan-archives+", "SAM------ Get the contents of archives (repeat for deep scanning)", &argsarray.argScanArchives,
            "scan-torrents", "SAM------ Get the contents of torrent files", &argsarray.argScanTorrents,
            "all", "SAM------ Enable checksums, file types, media info, and shallow archive/torrent scans", &argsarray.argAll,
            "archive-cache-dir", "S-M------ Root directory for archive member extraction", &argsarray.argArchiveCacheDir,
            "archive-cache-size", "S-M------ Archive member cache size in MiB", &argsarray.argArchiveCacheMiB,
            "drop-missing", "SA------- Drop missing files from database", &argsarray.argDropMissing,
            "threads", "SAM------ Number of worker threads", &argsarray.argNumberOfThreads,
            "replace", "S-----R-- Replace existing data (JSON scan or import)", &argsarray.argReplaceCatalog,
            "force", "------R-- Reinitialize an existing repository (init) or replace it (restore)", &argsarray.argForce,
            "pick-hidden", "S-------- Pick hidden files and directories too", &argsarray.argPickHidden,
            "dry-run", "--------J Compute JSON results without writing the catalog", &argsarray.argDryRun,
            "no-input", "-------G- Suppress interactive prompts and input", &argsarray.argNoInput,
            "restore-from", "------R-- Copy this recovery file over the catalog", &argsarray.argRestoreFrom,
            "merge-duplicates", "--------J Analyze and merge duplicates after scan", &argsarray.argMergeDuplicates,
            "pretty", "-------G- Indent saved JSON catalogs for human reading (scan, analyze, and export only)", &argsarray.argPrettyJSON,
            "verbose", "-------G- Be verbose", &argsarray.argVerboseOutputs,
            "text", "----L---- Filter listed catalog paths or SHA1 values", &argsarray.argQueryText,
            "limit", "----L---- Maximum number of listed catalog blobs", &argsarray.argQueryLimit,
            "offset", "----L---- Number of matching catalog blobs to skip", &argsarray.argQueryOffset,
            "video", "----L---- Require video metadata", &argsarray.argQueryVideo,
            "audio", "----L---- Require audio metadata", &argsarray.argQueryAudio,
            "image", "----L---- Require image metadata", &argsarray.argQueryImage,
            "text-stream", "----L---- Require text or subtitle metadata", &argsarray.argQueryTextStream,
            "file-type", "----L---- Require file type metadata", &argsarray.argQueryFileType,
            "archive", "----L---- Require a known archive index", &argsarray.argQueryArchive,
            "torrent", "----L---- Require torrent metadata", &argsarray.argQueryTorrent,
            "duplicate-limit", "-----D--- Maximum number of duplicate groups", &argsarray.argDuplicateLimit,
            "format", "---ILD--- Catalog query/status output format: table or json", &argsarray.argOutputFormat,
            "version", "-------G- Show the application version", &argsarray.argVersion);
    }
    catch (GetOptException ex)
    {
        errorLine("Invalid command-line arguments: ", ex.msg);
        errorLine("Use --help to see the available options.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }

    switch (command)
    {
    case "init":
        argsarray.argInitRepository = true;
        break;
    case "scan":
        argsarray.argScanFiles = true;
        break;
    case "metadata":
        argsarray.argRunMetadata = true;
        break;
    case "info":
        argsarray.argShowInfo = true;
        break;
    case "status":
        argsarray.argShowStatus = true;
        break;
    case "list":
        argsarray.argList = true;
        break;
    case "duplicates":
        argsarray.argDuplicates = true;
        break;
    case "analyze":
        argsarray.argRunAnalysis = true;
        break;
    case "import":
        argsarray.argImportJSON = argsarray.argJSONFile;
        break;
    case "export":
        if (argsarray.argExportJSON.empty)
            argsarray.argExportJSON = argsarray.argJSONFile;
        break;
    default:
        break;
    }
    if (argsarray.argAll)
    {
        /* --all is a convenience shortcut for the standard extractor set.
         * Explicitly repeated --scan-archives still selects deep scanning. */
        argsarray.argDoChecksums = true;
        argsarray.argDoFileTypes = true;
        argsarray.argDoMediaSig = true;
        if (argsarray.argScanArchives == 0)
            argsarray.argScanArchives = 1;
        argsarray.argScanTorrents = true;
    }
	argsarray.argScanArchivesOption = argsarray.argScanArchives > 0;

    if (helpInformation.helpWanted)
    {
        log(helpText);
        version (unittest)
        {
        }
        else
        {
            defaultGetoptPrinter("A file scanner and metadata scraper", helpInformation.options);
        }
        return ParsedCommandLine(ParseStatus.help, CliCommand.noCommand, argsarray);
    }
    if (argsarray.argVersion)
        return ParsedCommandLine(ParseStatus.showVersion, CliCommand.noCommand, argsarray);

    if (argsarray.argForce && command != "init" && command != "restore")
    {
        errorLine("--force is available only with init or restore.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }
    if (!argsarray.argRestoreInput.empty && command != "restore")
    {
        errorLine("--input is available only with restore.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }
    if (!argsarray.argExportJSON.empty && command != "export"
        && command != "backup")
    {
        errorLine("--output is available only with export or backup.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }

    if (command == "recover")
    {
        if (!rootArgument.empty)
            argsarray.argJSONFile = rootArgument;
        if (argsarray.argJSONFile.empty)
        {
            errorLine("recover requires a JSON catalog path.");
            return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
        }
        return ParsedCommandLine(ParseStatus.run, CliCommand.recover, argsarray);
    }

    const bool jsonMode = (command == "scan" || command == "analyze"
        || command == "list" || command == "duplicates"
        || command == "status")
        && !argsarray.argJSONFile.empty;
    if (jsonMode)
    {
        if (argsarray.argBaseDir.empty)
            argsarray.argBaseDir = rootArgument.empty ? "." : rootArgument;
        if (argsarray.argJSONFile.empty)
            argsarray.argJSONFile = catalogArgument;
    }
    else if (!rootArgument.empty)
        argsarray.argRepositoryPath = rootArgument;

    if (args.length > 1)
    {
        errorLine("Unexpected positional argument: ", args[1]);
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }

    setVerboseOutputs(argsarray.argVerboseOutputs);
    if (command.empty)
    {
        errorLine("Choose a command. Use --help to see available commands.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }
    if (argsarray.argAll && command != "scan" && command != "metadata"
        && command != "analyze")
    {
        errorLine("--all is available only with scan, metadata, or analyze.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    }

    if (jsonMode)
    {
        if (!validateJsonOptions(command, argsarray))
            return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
        return ParsedCommandLine(ParseStatus.run, commandToCliCommand(command), argsarray);
    }

    if (!validateRepositoryOptions(command, argsarray))
        return ParsedCommandLine(ParseStatus.error, CliCommand.noCommand, argsarray);
    return ParsedCommandLine(ParseStatus.run, commandToCliCommand(command), argsarray);
}

/** Map a recognized command token to its typed action.
 *
 * Params:
 *   command = Command token accepted by the parser.
 * Returns: The matching `CliCommand`; `noCommand` for an empty token.
 */
private CliCommand commandToCliCommand(string command)
{
    final switch (command)
    {
    case "init":
        return CliCommand.init;
    case "scan":
        return CliCommand.scan;
    case "metadata":
        return CliCommand.metadata;
    case "info":
        return CliCommand.info;
    case "status":
        return CliCommand.status;
    case "list":
        return CliCommand.list;
    case "duplicates":
        return CliCommand.duplicates;
    case "analyze":
        return CliCommand.analyze;
    case "import":
        return CliCommand.importJson;
    case "export":
        return CliCommand.exportJson;
    case "backup":
        return CliCommand.backup;
    case "restore":
        return CliCommand.restore;
    case "recover":
        return CliCommand.recover;
    case "":
        return CliCommand.noCommand;
    }
}

@("explicit sqlite and json command modes")
unittest
{
    enum root = "./test/";
    enum catalog = "./test/json_file_test.json";

    auto sqliteScan = parseCommandLine(["programname", "scan", root,
        "--recursive"]);
    assert(sqliteScan.status == ParseStatus.run);
    assert(sqliteScan.command == CliCommand.scan);
    assert(sqliteScan.options.argRepositoryPath == root);

    auto jsonScanTopLevel = parseCommandLine(["programname", "scan", root,
        "--json", catalog, "--recursive"]);
    assert(jsonScanTopLevel.status == ParseStatus.run);
    assert(jsonScanTopLevel.command == CliCommand.scan);
    assert(jsonScanTopLevel.options.argBaseDir == root);
    assert(jsonScanTopLevel.options.argJSONFile == catalog);
    assert(jsonScanTopLevel.options.argScanFiles);

    auto jsonAnalyzeTopLevel = parseCommandLine(["programname", "analyze",
        "--json", "./test/json_file_v2.json"]);
    assert(jsonAnalyzeTopLevel.status == ParseStatus.run);
    assert(jsonAnalyzeTopLevel.command == CliCommand.analyze);
    assert(jsonAnalyzeTopLevel.options.argBaseDir == ".");
    assert(jsonAnalyzeTopLevel.options.argJSONFile == "./test/json_file_v2.json");
    assert(jsonAnalyzeTopLevel.options.argRunAnalysis);
}

@("parser validates command boundaries and isolates consecutive parses")
unittest
{
    auto init = parseCommandLine(["program", "init", "./test"]);
    assert(init.status == ParseStatus.run && init.command == CliCommand.init);

    auto metadata = parseCommandLine(["program", "metadata", "./test",
        "--checksums"]);
    assert(metadata.status == ParseStatus.run
        && metadata.command == CliCommand.metadata);
    assert(metadata.options.argDoChecksums);

    const auto verboseBeforeMetadataOptions = isVerboseOutputs();
    scope (exit)
        setVerboseOutputs(verboseBeforeMetadataOptions);
    auto allMetadataOptions = parseCommandLine(["program", "metadata", "./test",
        "--checksums", "--file-types", "--media-info", "--scan-archives",
        "--scan-torrents", "--verbose"]);
    assert(allMetadataOptions.status == ParseStatus.run);
    assert(allMetadataOptions.options.argDoChecksums);
    assert(allMetadataOptions.options.argDoFileTypes);
    assert(allMetadataOptions.options.argDoMediaSig);
    assert(allMetadataOptions.options.argScanArchives == 1);
    assert(allMetadataOptions.options.argScanArchivesOption);
    assert(allMetadataOptions.options.argScanTorrents);
    auto allShortcut = parseCommandLine(["program", "scan", "./test", "--all"]);
    assert(allShortcut.status == ParseStatus.run);
    assert(allShortcut.options.argAll);
    assert(allShortcut.options.argDoChecksums);
    assert(allShortcut.options.argDoFileTypes);
    assert(allShortcut.options.argDoMediaSig);
    assert(allShortcut.options.argScanArchives == 1);
    assert(allShortcut.options.argScanArchivesOption);
    assert(allShortcut.options.argScanTorrents);
    auto allDeepArchive = parseCommandLine(["program", "scan", "./test",
        "--all", "--scan-archives", "--scan-archives"]);
    assert(allDeepArchive.status == ParseStatus.run);
    assert(allDeepArchive.options.argScanArchives == 2);
    assert(allDeepArchive.options.argScanArchivesOption);
    assert(helpText.canFind("--all"));
    auto allInfo = parseCommandLine(["program", "info", "./test", "--all"]);
    assert(allInfo.status == ParseStatus.error);
    auto allJsonAnalyze = parseCommandLine(["program", "analyze",
        "--json", "./test/json_file_v2.json", "--all"]);
    assert(allJsonAnalyze.status == ParseStatus.run);
    assert(allJsonAnalyze.options.argDoChecksums);
    assert(allJsonAnalyze.options.argDoFileTypes);
    assert(allJsonAnalyze.options.argDoMediaSig);
    assert(allJsonAnalyze.options.argScanArchives == 1);
    assert(allJsonAnalyze.options.argScanTorrents);
    auto deepArchive = parseCommandLine(["program", "metadata", "./test",
        "--scan-archives", "--scan-archives"]);
    assert(deepArchive.status == ParseStatus.run);
    assert(deepArchive.options.argScanArchives == 2);
    assert(deepArchive.options.argScanArchivesOption);
    auto cachedArchive = parseCommandLine(["program", "scan", "./test",
        "--scan-archives", "--archive-cache-dir", "./cache",
        "--archive-cache-size", "64"]);
    assert(cachedArchive.status == ParseStatus.run);
    assert(cachedArchive.options.argArchiveCacheDir == "./cache");
    assert(cachedArchive.options.argArchiveCacheMiB == 64);
    auto prettyExport = parseCommandLine(["program", "export", "./test",
        "--output=./test/export.json", "--pretty"]);
    assert(prettyExport.status == ParseStatus.run);
    assert(prettyExport.options.argPrettyJSON);
    assert(allMetadataOptions.options.argVerboseOutputs);
    assert(helpText.canFind("--checksums"));
    assert(helpText.canFind("--file-types"));
    assert(helpText.canFind("--media-info"));
    assert(helpText.canFind("--scan-archives"));
    assert(helpText.canFind("--scan-torrents"));
    assert(helpText.canFind("--archive-cache-dir"));
    assert(helpText.canFind("--archive-cache-size"));
    assert(helpText.canFind("--pretty"));
    assert(helpText.canFind("--no-input"));
    assert(helpText.canFind("--force"));
    assert(helpText.canFind("--input"));
    assert(helpText.canFind("backup"));
    assert(helpText.canFind("restore"));
    auto backupCommand = parseCommandLine(["program", "backup", "./test",
        "--output", "./test/backup.sqlite3"]);
    assert(backupCommand.status == ParseStatus.run);
    assert(backupCommand.command == CliCommand.backup);
    assert(backupCommand.options.argExportJSON == "./test/backup.sqlite3");
    auto restoreCommand = parseCommandLine(["program", "restore", "./test",
        "--input", "./test/backup.sqlite3", "--force"]);
    assert(restoreCommand.status == ParseStatus.run);
    assert(restoreCommand.command == CliCommand.restore);
    assert(restoreCommand.options.argRestoreInput == "./test/backup.sqlite3");
    assert(restoreCommand.options.argForce);
    assert(helpText.canFind("recover"));
    assert(helpText.canFind("--verbose"));
    assert(helpText.canFind("S A M I L D R G J"));
    auto forcedInit = parseCommandLine(["program", "init", "./test",
        "--force"]);
    assert(forcedInit.status == ParseStatus.run);
    assert(forcedInit.options.argInitRepository);
    assert(forcedInit.options.argForce);
    auto invalidForce = parseCommandLine(["program", "scan", "./test",
        "--force"]);
    assert(invalidForce.status == ParseStatus.error);
    auto outdatedMetadataFlag = parseCommandLine(["program", "metadata",
        "./test", "--checksum"]);
    assert(outdatedMetadataFlag.status == ParseStatus.error);

    auto analysis = parseCommandLine(["program", "analyze", "./test",
        "--drop-missing"]);
    assert(analysis.status == ParseStatus.run
        && analysis.command == CliCommand.analyze);
    assert(analysis.options.argDropMissing);

    auto info = parseCommandLine(["program", "info", "./test", "--format=json"]);
    assert(info.status == ParseStatus.run && info.command == CliCommand.info);
    assert(info.options.argOutputFormat == "json");

    auto status = parseCommandLine(["program", "status", "./test",
        "--format=json"]);
    assert(status.status == ParseStatus.run
        && status.command == CliCommand.status);
    assert(status.options.argShowStatus);
    assert(status.options.argOutputFormat == "json");

    auto jsonStatus = parseCommandLine(["program", "status", "--json",
        "./test/json_file_v2.json", "--base-dir", "./test", "--format=json"]);
    assert(jsonStatus.status == ParseStatus.run
        && jsonStatus.command == CliCommand.status);
    assert(jsonStatus.options.argJSONFile == "./test/json_file_v2.json");
    assert(jsonStatus.options.argBaseDir == "./test");
    assert(jsonStatus.options.argShowStatus);

    auto invalidStatus = parseCommandLine(["program", "status", "./test",
        "--text=needle"]);
    assert(invalidStatus.status == ParseStatus.error);

    auto list = parseCommandLine(["program", "list", "./test", "--text=needle",
        "--limit=10", "--offset=1", "--video", "--format=json"]);
    assert(list.status == ParseStatus.run && list.command == CliCommand.list);
    assert(list.options.argQueryText == "needle");
    assert(list.options.argQueryLimit == 10 && list.options.argQueryOffset == 1);
    assert(list.options.argQueryVideo && list.options.argOutputFormat == "json");

    auto duplicates = parseCommandLine(["program", "duplicates", "./test",
        "--duplicate-limit=5", "--format=json"]);
    assert(duplicates.status == ParseStatus.run
        && duplicates.command == CliCommand.duplicates);
    assert(duplicates.options.argDuplicateLimit == 5);

    auto imported = parseCommandLine(["program", "import", "./test",
        "./test/json_file_v1.json", "--replace"]);
    assert(imported.status == ParseStatus.run
        && imported.command == CliCommand.importJson);
    assert(imported.options.argRepositoryPath == "./test");
    assert(imported.options.argImportJSON == "./test/json_file_v1.json");
    assert(imported.options.argReplaceCatalog);

    auto exported = parseCommandLine(["program", "export", "./test",
        "--output=./test/export.json",
        "--path=archives/sample.zip!/payload/copy.txt"]);
    assert(exported.status == ParseStatus.run
        && exported.command == CliCommand.exportJson);
    assert(exported.options.argExportJSON == "./test/export.json");
    assert(exported.options.argExportPath
        == "archives/sample.zip!/payload/copy.txt");

    auto jsonScan = parseCommandLine(["program", "scan", "./test",
        "--json", "./test/out.json", "--recursive", "--checksums"]);
    assert(jsonScan.status == ParseStatus.run
        && jsonScan.command == CliCommand.scan);
    assert(jsonScan.options.argBaseDir == "./test");
    assert(jsonScan.options.argJSONFile == "./test/out.json");

    auto jsonScanNoInput = parseCommandLine(["program", "scan", "./test",
        "--json", "./test/out.json", "--no-input"]);
    assert(jsonScanNoInput.status == ParseStatus.run);
    assert(jsonScanNoInput.options.argNoInput);

    auto recovery = parseCommandLine(["program", "recover",
        "./test/catalog.json", "--restore-from", "./test/backup.json"]);
    assert(recovery.status == ParseStatus.run);
    assert(recovery.command == CliCommand.recover);
    assert(recovery.options.argJSONFile == "./test/catalog.json");
    assert(recovery.options.argRestoreFrom == "./test/backup.json");

    auto jsonScanMergeDryRun = parseCommandLine(["program", "scan",
        "./test", "--json", "./test/out.json", "--checksums",
        "--merge-duplicates", "--dry-run"]);
    assert(jsonScanMergeDryRun.status == ParseStatus.run);
    assert(jsonScanMergeDryRun.options.argMergeDuplicates);
    assert(jsonScanMergeDryRun.options.argDryRun);
    assert(helpText.canFind("--merge-duplicates"));
    assert(helpText.canFind("--dry-run"));

    auto jsonAnalyze = parseCommandLine(["program", "analyze",
        "--json", "./test/json_file_v1.json", "--drop-missing",
        "--dry-run"]);
    assert(jsonAnalyze.status == ParseStatus.run
        && jsonAnalyze.command == CliCommand.analyze);
    assert(jsonAnalyze.options.argBaseDir == ".");
    assert(jsonAnalyze.options.argDryRun);

    auto invalidRepositoryDryRun = parseCommandLine(["program", "scan",
        "./test", "--dry-run"]);
    assert(invalidRepositoryDryRun.status == ParseStatus.error);
    auto invalidJsonAnalyzeMerge = parseCommandLine(["program", "analyze",
        "--json", "./test/json_file_v1.json", "--merge-duplicates"]);
    assert(invalidJsonAnalyzeMerge.status == ParseStatus.error);

    auto invalidSqliteOption = parseCommandLine(["program", "scan", "./test",
        "--limit=5"]);
    assert(invalidSqliteOption.status == ParseStatus.error);

    auto extraPosition = parseCommandLine(["program", "scan", "./test",
        "./test/unexpected.json"]);
    assert(extraPosition.status == ParseStatus.error);

    auto invalidFormat = parseCommandLine(["program", "list", "./test",
        "--format=xml"]);
    assert(invalidFormat.status == ParseStatus.error);

    auto invalidJsonQuery = parseCommandLine(["program", "scan", "./test",
        "--json", "./test/out.json", "--text=needle"]);
    assert(invalidJsonQuery.status == ParseStatus.error);

    auto missingJsonCatalog = parseCommandLine(["program", "scan",
        "./test", "--json"]);
    assert(missingJsonCatalog.status == ParseStatus.error);

    auto invalidJsonScanOption = parseCommandLine(["program", "scan",
        "./test", "--json", "./test/out.json", "--drop-missing"]);
    assert(invalidJsonScanOption.status == ParseStatus.error);

    auto unsupported = parseCommandLine(["program", "metadata", "./test"]);
    assert(unsupported.status == ParseStatus.error);

    auto first = parseCommandLine(["program", "scan", "./test", "--recursive",
        "--checksums"]);
    assert(first.status == ParseStatus.run);
    auto second = parseCommandLine(["program", "info", "./test"]);
    assert(second.status == ParseStatus.run);
    assert(!second.options.argRecursive);
    assert(!second.options.argDoChecksums);
    assert(second.options.argQueryText.length == 0);
    assert(second.options.argOutputFormat == "table");

    auto help = parseCommandLine(["program", "--help"]);
    assert(help.status == ParseStatus.help);
    auto helpWithTrailingArgument = parseCommandLine(["program", "--help", "scan"]);
    assert(helpWithTrailingArgument.status == ParseStatus.help);
    auto versionResult = parseCommandLine(["program", "--version"]);
    assert(versionResult.status == ParseStatus.showVersion);
}

/** Shortens a string `s` to exactly `maxLen` characters.
 *
 * The result keeps the start and end intact so file names remain readable in
 * narrow terminal columns.
 *
 * Params:
 *   str = input string.
 *   maxLen = target maximum length.
 * Returns:
 *   A string shortened from the middle if needed.
 */
dstring shortenMiddle(string str, size_t maxLen)
{
    import std.utf : validate;

    enum ellipsis = "..."d;
    enum ellipsisLen = ellipsis.length;

    assertNotThrown(str.validate, str);

    // Convert to dstring to have simple and safe unicode operations.
    dstring dstr = str.to!dstring;

    // Simple cases
    if (dstr.length <= maxLen || maxLen == 0)
        return dstr;
    // If maxLen is too small to reasonably include "...",
    // just return the first maxLen characters.
    if (maxLen <= ellipsisLen)
        return dstr[0 .. maxLen];

    // Remaining characters available for prefix + suffix
    auto remain = maxLen - ellipsisLen;

    // Split between start and end parts
    auto headLen = remain / 2 + (remain % 2); // odd -> one extra in the front
    auto tailLen = remain - headLen;

    auto head = dstr[0 .. headLen];
    auto tail = dstr[$ - tailLen .. $];

    auto result = (head ~ ellipsis ~ tail);

    return result;
}

@("shortenMiddle")
unittest
{
    auto type0 = shortenMiddle("123456", 3);
    assert(type0 == "123"d, type0.to!string);

    auto str1 = "test/dummy-text-file.txt";
    auto type1 = shortenMiddle(str1, 60);
    assert(type1 == str1.to!dstring, type1.to!string);
    assert(type1.length == str1.length, type1.to!string);

    auto str2 = "test/test2/test3/test4/very-long-dummy-very-long-audio-file.mp3";
    auto type2 = shortenMiddle(str2, 60);
    auto str2a = "test/test2/test3/test4/very-l...mmy-very-long-audio-file.mp3"d;
    assert(type2 == str2a, type2.to!string);
    assert(type2.length == 60, type2.to!string);

    auto type3 = shortenMiddle(`さいごの果実 / ミツバチと科学者`, 10);
    assert(type3 == "さいごの...科学者"d, type3.to!string);
    assert(type3.length == 10, type3.to!string);

    auto type4 = shortenMiddle("|aaaa|bbbb|cccc|dddd|eeee|ffff|gggg|hhhh", 15);
    assert(type4.length == 15, type4.to!string);
    assert(type4 == "|aaaa|...g|hhhh", type4.to!string);
}

/** Pad whitespace to the left side of a string.
 *
 * This is used to keep the progress display aligned across varying file names.
 *
 * Params:
 *   s = input string
 *   padlen = target length after left-padding
 * Returns:
 *   padded string, or the original string if it is already longer than `padlen`
 */
dstring padLeft(dstring s, size_t padlen)
{
    size_t slen = s.length;
    if (slen > padlen)
        return s;

    size_t plen = padlen - slen;
    auto pad = " ".cycle.take(plen).array.to!dstring;

    // auto rv = s ~ pad;
    auto rv = pad ~ s;
    return rv;
}

unittest
{
    dstring a = "!--- !--- !--- ";
    dstring a1 = padLeft(a, 10);
    assert(a == a1, a1.to!string);

    dstring a2 = padLeft(a, 15);
    assert(a == a2, a2.to!string);

    dstring a3 = padLeft(a, 20);
    dstring b3 = "     !--- !--- !--- "d;
    assert(b3 == a3, a3.to!string);

}

/** Wrapper around a progress callback function pointer. */
struct ProgressCallBack
{
    /// Callback receiving the completed count and total count.
    void function(size_t i, size_t m) fp;
}

/** Create a spinner character plus normalized progress text.
 *
 * The spinner gives a sense of liveliness when the progress ratio is not
 * changing visibly.
 *
 * Params:
 *   i = current value
 *   m = maximum value
 * Returns:
 *   progress string in the form `<spinner> <ratio>`
 */
string makeProgressString(size_t i, size_t m)
{
    import dosierskanilo.logging;
    import std.range;

    static int q = 0;
    char[] p = ['-', '\\', '|', '/', '-', '|', '/', '-'];
    auto result = format("%c %.6f", p[q++], (i.to!float / m.to!float));
    q &= 0x7;
    return result;
}

@("makeProgressString")
unittest
{
    auto s1 = makeProgressString(0, 100);
    assert(searching.startsWith(s1, "- 0.000000"), s1);
    auto s2 = makeProgressString(50, 100);
    assert(searching.startsWith(s2, "\\ 0.500000"), s2);
    auto s3 = makeProgressString(100, 100);
    assert(searching.startsWith(s3, "| 1.000000"), s3);
}

/** Update progress output for a sub-task callback.
 *
 * This is called from background jobs and renders their progress inline with
 * the main scanner progress line.
 *
 * Params:
 *   i = current value
 *   m = maximum value
 */
void progressCallBack(size_t i, size_t m)
{
    //log(makeProgressString(i, m));
    printProgress(lastIdx, lastTotalFiles, lastFile, makeProgressString(i, m));
}

import std.datetime;

/// Timestamp of the last main progress line, used for throttling.
private __gshared SysTime lastProgress;
/// Most recent completed item count passed to `printProgress`.
private __gshared size_t lastIdx;
/// Most recent total item count passed to `printProgress`.
private __gshared size_t lastTotalFiles;
/// Most recent file path passed to `printProgress`.
private __gshared string lastFile;
/// Timestamp of the last emitted operation progress event.
private __gshared SysTime lastOperationProgress;
/// Text form of the most recently reported operation phase.
private __gshared string lastOperationPhase;
/// True while a compact progress line is open on the terminal.
private __gshared bool operationProgressLineOpen;
/// Start time of the current operation, or `SysTime.init` when unknown.
private __gshared SysTime operationStartedAt;
/// Label shown in the operation header.
private __gshared string operationContextLabel;
/// Optional secondary detail shown in the operation header.
private __gshared string operationContextDetail;
/// True after the operation header has been printed.
private __gshared bool operationHeaderPrinted;
/// Mutex guarding the cross-thread operation heartbeat state.
private __gshared Mutex operationStateMutex;
/// True while the heartbeat thread should keep running.
private __gshared bool operationHeartbeatActive;
/// Generation counter that invalidates earlier heartbeat threads.
private __gshared uint operationHeartbeatGeneration;
/// Most recent operation progress event, kept for heartbeat output.
private __gshared OperationProgress lastOperationEvent;
/// True when `lastOperationEvent` holds a valid event.
private __gshared bool haveLastOperationEvent;

/** Operation control used by the heartbeat to surface cancellation. */
private __gshared OperationControl activeOperationControl;

/** Initialize the shared operation-state mutex. */
shared static this()
{
    operationStateMutex = new Mutex;
}


/** Return whether stdout is attached to a terminal.
 *
 * On non-POSIX targets this always returns `false`.
 *
 * Returns: `true` when stdout is an interactive terminal.
 */
private bool stdoutIsTerminal()
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        return isatty(STDOUT_FILENO) != 0;
    }
    else
        return false;
}

/** Whether stdout accepts ANSI color sequences.
 *
 * Honors `NO_COLOR` and `CLICOLOR_FORCE`; the result is cached for the
 * process lifetime.
 *
 * Returns: `true` when ANSI color output should be emitted.
 */
private bool supportsColor()
{
    static int cached = -1;
    if (cached >= 0)
        return cached != 0;

    bool enabled = stdoutIsTerminal();
    const term = environment.get("TERM", "");
    if (term == "dumb" || !environment.get("NO_COLOR", "").empty)
        enabled = false;
    if (environment.get("CLICOLOR_FORCE", "") == "1")
        enabled = true;
    cached = enabled ? 1 : 0;
    return enabled;
}

/** Return the usable terminal width in columns.
 *
 * Uses `$COLUMNS` when it holds a value of at least 40, then the POSIX window
 * size, and otherwise a conservative default.
 *
 * Returns: Positive column count suitable for bounding progress lines.
 */
private size_t terminalColumns()
{
    const configured = environment.get("COLUMNS", "");
    if (!configured.empty)
    {
        try
        {
            const columns = configured.to!size_t;
            if (columns >= 40)
                return columns;
        }
        catch (Exception)
        {
        }
    }
    version (Posix)
    {
        winsize size;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0)
            return cast(size_t) size.ws_col;
    }
    return stdoutIsTerminal() ? 80 : 100;
}

/** Return the human-readable label for an operation phase.
 *
 * Params:
 *   phase = phase to translate.
 * Returns: Short English label used in progress output.
 */
private string operationPhaseLabel(OperationPhase phase)
{
    final switch (phase)
    {
    case OperationPhase.none: return "working";
    case OperationPhase.validating: return "validating";
    case OperationPhase.discovering: return "discovering";
    case OperationPhase.scanning: return "scanning";
    case OperationPhase.reconcilingMissingFiles: return "checking missing files";
    case OperationPhase.checksums: return "checksums";
    case OperationPhase.fileTypes: return "file types";
    case OperationPhase.mediaInfo: return "media info";
    case OperationPhase.archives: return "archives";
    case OperationPhase.torrents: return "torrents";
    case OperationPhase.analysisMissingFiles: return "missing files";
    case OperationPhase.analysisDuplicates: return "duplicates";
    case OperationPhase.analysisCleanup: return "analysis cleanup";
    case OperationPhase.jsonRead: return "reading JSON";
    case OperationPhase.jsonWrite: return "writing JSON";
    }
}

/** Format a byte count using binary units.
 *
 * Params:
 *   bytes = raw byte count.
 * Returns: Value with one decimal place and a unit from `B` through `TiB`.
 */
string formatProgressBytes(ulong bytes)
{
    immutable string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
    real value = bytes;
    size_t unit;
    while (value >= 1024 && unit + 1 < units.length)
    {
        value /= 1024;
        unit++;
    }
    return format("%.1f %s", value, units[unit]);
}

/** Format a count with thousands separators.
 *
 * Params:
 *   value = Count to format.
 * Returns: Decimal text with `,` between each group of three digits.
 */
string formatProgressCount(ulong value)
{
    const text = value.to!string;
    string result;
    foreach (index, character; text)
    {
        if (index > 0 && (text.length - index) % 3 == 0)
            result ~= ',';
        result ~= character;
    }
    return result;
}

@("formatProgressCount groups thousands")
unittest
{
    assert(formatProgressCount(0) == "0");
    assert(formatProgressCount(999) == "999");
    assert(formatProgressCount(1000) == "1,000");
    assert(formatProgressCount(2600000) == "2,600,000");
}

/** Format an elapsed duration compactly.
 *
 * Params:
 *   elapsed = duration to format.
 * Returns: `Ns`, `NmSSs`, or `NhMMm`, depending on magnitude.
 */
private string formatElapsed(Duration elapsed)
{
    const seconds = elapsed.total!"seconds";
    if (seconds < 60)
        return format("%ds", seconds);
    if (seconds < 3600)
        return format("%dm%02ds", seconds / 60, seconds % 60);
    return format("%dh%02dm", seconds / 3600, seconds % 3600 / 60);
}

/** Format a wall-clock time as a log-line prefix.
 *
 * Params:
 *   now = time to format.
 * Returns: `[HH:MM:SS] ` including the trailing space.
 */
private string formatTimestamp(SysTime now)
{
    return format("[%02d:%02d:%02d] ", now.hour, now.minute, now.second);
}

/** Prepare operation output without writing anything yet.
 *
 * The header is printed lazily on the first progress event, so failed
 * operations that never acquire their target do not pollute stdout.
 *
 * Params:
 *   label = Primary operation label shown in the header.
 *   detail = Optional secondary context shown in the header.
 *   control = Active operation control, used to surface cancellation even
 *       when the operation emits no further progress events.
 */
void prepareOperationOutput(string label, string detail = "",
    OperationControl control = null)
{
    operationContextLabel = label;
    operationContextDetail = detail;
    activeOperationControl = control;
    operationHeaderPrinted = false;
    operationStartedAt = Clock.currTime;
    lastOperationProgress = SysTime.init;
    lastOperationPhase = "";
    operationProgressLineOpen = false;
    synchronized (operationStateMutex)
    {
        operationHeartbeatGeneration++;
        operationHeartbeatActive = true;
        haveLastOperationEvent = false;
    }
    startOperationHeartbeat(operationHeartbeatGeneration);
}

/** Start the daemon thread that emits periodic heartbeat output.
 *
 * The thread exits once the generation counter or the active flag shows that
 * its operation has been superseded.
 *
 * Params:
 *   generation = heartbeat generation identifying the current operation.
 */
private void startOperationHeartbeat(uint generation)
{
    auto thread = new Thread({
        while (true)
        {
            Thread.sleep(dur!"seconds"(2));
            bool active;
            synchronized (operationStateMutex)
                active = operationHeartbeatActive
                    && operationHeartbeatGeneration == generation;
            if (!active)
                return;
            printOperationHeartbeat(generation);
        }
    });
    thread.isDaemon = true;
    thread.start();
}

/** Emit a heartbeat when no progress callback arrived for several seconds.
 *
 * Params:
 *   generation = Heartbeat generation that must still be current.
 */
private void printOperationHeartbeat(uint generation)
{
    import dosierskanilo.logging : logF, logFLine;

    OperationProgress event;
    bool haveEvent;
    SysTime lastEventTime;
    synchronized (operationStateMutex)
    {
        if (!operationHeartbeatActive
            || operationHeartbeatGeneration != generation)
            return;
        event = lastOperationEvent;
        haveEvent = haveLastOperationEvent;
        lastEventTime = lastOperationProgress;
    }

    const auto now = Clock.currTime;
    const auto control = activeOperationControl;
    const bool cancelling = control !is null && control.cancellationRequested;
    if (!cancelling && lastEventTime != SysTime.init
        && now - lastEventTime < dur!"seconds"(3))
        return;
    if (cancelling)
    {
        event.state = OperationState.cancelling;
        event.message = "Cancellation requested; waiting for current work to stop.";
    }

    const auto elapsed = operationStartedAt == SysTime.init
        ? Duration.zero : now - operationStartedAt;
    const bool tty = stdoutIsTerminal();
    if (!haveEvent)
    {
        auto line = format("%swaiting for first progress update  %s",
            cancelling ? "cancelling  " : "", formatElapsed(elapsed));
        if (tty)
            logF("\r\x1b[K%s", line);
        else
            logFLine("%s%s", formatTimestamp(now), line);
        return;
    }

    auto line = formatOperationProgressLine(event, terminalColumns(),
        tty && supportsColor(), elapsed, true);
    if (lastEventTime != SysTime.init
        && now - lastEventTime > dur!"seconds"(5))
        line = "waiting  " ~ line;
    if (tty)
        logF("\r\x1b[K%s", line);
    else
        logFLine("%s%s", formatTimestamp(now), line);
}

/** Print the operation header at most once for the current operation.
 *
 * The first caller prints `operationContextLabel` and
 * `operationContextDetail`; later callers do nothing.
 */
private void ensureOperationHeader()
{
    synchronized (operationStateMutex)
    {
        if (operationHeaderPrinted)
            return;
        operationHeaderPrinted = true;
    }
    printOperationStart(operationContextLabel, operationContextDetail);
}

/** Print the one-line operation header.
 *
 * The header names the operation and its target once. Progress lines that
 * follow intentionally do not repeat that context.
 *
 * Params:
 *   label = Primary operation label.
 *   detail = Optional secondary context appended to the label.
 */
void printOperationStart(string label, string detail = "")
{
    import dosierskanilo.logging : logFLine;

    if (operationStartedAt == SysTime.init)
        operationStartedAt = Clock.currTime;
    lastOperationProgress = SysTime.init;
    lastOperationPhase = "";
    operationProgressLineOpen = false;

    if (supportsColor())
    {
        auto line = "\x1b[1m" ~ label ~ "\x1b[0m";
        if (!detail.empty)
            line ~= "  \x1b[2m" ~ detail ~ "\x1b[0m";
        logFLine("%s", line);
    }
    else
    {
        auto line = label;
        if (!detail.empty)
            line ~= "  " ~ detail;
        logFLine("%s", line);
    }
}

/** Format one compact, width-bounded progress line.
 *
 * The operation label is intentionally absent: it was already printed by
 * `printOperationStart`. The remaining fields are phase, counts, elapsed time,
 * optional rate/subtask details, and the current path.
 *
 * Params:
 *   event = Operation progress event to render.
 *   columns = Maximum line width; zero selects 80 columns.
 *   colorize = Whether to wrap fields in ANSI color sequences.
 *   elapsed = Elapsed operation time, or zero to omit timing.
 *   detailed = Whether to include the completion rate in detailed mode.
 * Returns: A progress line no longer than `columns` characters.
 */
string formatOperationProgressLine(OperationProgress event, size_t columns,
    bool colorize = false, Duration elapsed = Duration.zero,
    bool detailed = false)
{
    if (columns == 0)
        columns = 80;

    auto phase = operationPhaseLabel(event.phase);
    if (columns < 60 && phase.length > 14)
        phase = shortenMiddle(phase, 14).to!string;

    string progress;
    if (event.totalKnown && event.total > 0)
    {
        const boundedCompleted = event.completed < event.total
            ? event.completed : event.total;
        const percent = cast(size_t)(cast(real) boundedCompleted * 100
            / event.total);
        if (columns >= 72)
        {
            const barWidth = columns >= 110 ? 16 : 10;
            const filled = percent * barWidth / 100;
            string bar = "[";
            foreach (index; 0 .. barWidth)
                bar ~= index < filled ? '=' : ' ';
            bar ~= "]";
            progress = format("%s %3d%% %s/%s", bar, percent,
                formatProgressCount(boundedCompleted),
                formatProgressCount(event.total));
        }
        else
            progress = format("%s/%s %3d%%",
                formatProgressCount(boundedCompleted),
                formatProgressCount(event.total), percent);
    }
    else if (event.completed > 0)
        progress = format("%s items", formatProgressCount(event.completed));

    if (event.subtaskTotalKnown && columns >= 72)
    {
        const subtask = event.subtaskUnit == "bytes"
            ? format("%s/%s", formatProgressBytes(event.subtaskCompleted),
                formatProgressBytes(event.subtaskTotal))
            : format("%s/%s %s",
                formatProgressCount(event.subtaskCompleted),
                formatProgressCount(event.subtaskTotal), event.subtaskUnit);
        progress ~= "  " ~ subtask;
    }

    string timing;
    if (elapsed > Duration.zero)
    {
        timing = formatElapsed(elapsed);
        if (detailed && elapsed.total!"seconds" > 0 && event.completed > 0)
        {
            const real rate = event.completed
                / cast(real) elapsed.total!"seconds";
            timing ~= rate >= 10.0
                ? format("  %s/s", formatProgressCount(cast(ulong) rate))
                : format("  %.1f/s", rate);
        }
    }

    string prefix = progress.empty ? phase : phase ~ "  " ~ progress;
    if (event.state == OperationState.cancelling)
        prefix = "cancelling  " ~ prefix;
    else if (event.state == OperationState.paused)
        prefix = "paused  " ~ prefix;
    if (!timing.empty)
        prefix ~= "  " ~ timing;

    const detail = event.path.length > 0 ? event.path : event.message;
    const available = columns > prefix.length + 1
        ? columns - prefix.length - 1 : 0;
    string visibleDetail = detail;
    if (visibleDetail.length > available)
        visibleDetail = available > 0
            ? shortenMiddle(visibleDetail, available).to!string : "";

    const plain = visibleDetail.empty ? prefix : prefix ~ " " ~ visibleDetail;
    if (plain.length > columns)
        return shortenMiddle(plain, columns).to!string;
    if (!colorize)
        return plain;

    auto colored = "\x1b[36m" ~ phase ~ "\x1b[0m";
    if (!progress.empty)
        colored ~= "  \x1b[32m" ~ progress ~ "\x1b[0m";
    if (!timing.empty)
        colored ~= "  \x1b[2m" ~ timing ~ "\x1b[0m";
    if (!visibleDetail.empty)
        colored ~= "  \x1b[2m" ~ visibleDetail ~ "\x1b[0m";
    return colored;
}

/** Render compact shared-operation progress on one throttled terminal line.
 *
 * On a terminal this is a single rewritten line. When stdout is redirected,
 * emit periodic newline records instead so logs remain readable.
 *
 * Params:
 *   label = Ignored operation label; the header already printed it.
 *   event = Operation progress event to render.
 */
void printOperationProgress(string label, OperationProgress event)
{
    import dosierskanilo.logging : logF, logFLine;

    ensureOperationHeader();
    const auto phase = event.phase.to!string;
    const auto now = Clock.currTime;
    const bool phaseChanged = phase != lastOperationPhase;
    const bool tty = stdoutIsTerminal();

    if (!phaseChanged && lastOperationProgress != SysTime.init)
    {
        const auto interval = tty ? dur!"msecs"(100) : dur!"seconds"(5);
        if (now - lastOperationProgress < interval)
            return;
    }

    const auto elapsed = operationStartedAt == SysTime.init
        ? Duration.zero : now - operationStartedAt;
    auto line = formatOperationProgressLine(event, terminalColumns(),
        tty && supportsColor(), elapsed, false);
    if (tty)
        logF("\r\x1b[K%s", line);
    else
        logFLine("%s%s", formatTimestamp(now), line);

    operationProgressLineOpen = tty;
    lastOperationPhase = phase;
    lastOperationProgress = now;
    synchronized (operationStateMutex)
    {
        lastOperationEvent = event;
        haveLastOperationEvent = true;
    }
}

/** Print verbose operation progress as throttled newline records.
 *
 * Verbose mode keeps a scrollable history instead of rewriting one line. It
 * adds rate information and is printed at most once per second, on phase
 * changes, and whenever the caller explicitly reports an event.
 *
 * Params:
 *   label = Ignored operation label; the header already printed it.
 *   event = Operation progress event to render.
 *   lastProgress = Timestamp of the previous verbose line; updated on output.
 *   haveProgress = Whether `lastProgress` holds a previous timestamp.
 */
void printVerboseOperationProgress(string label, OperationProgress event,
    ref SysTime lastProgress, ref bool haveProgress)
{
    import dosierskanilo.logging : logF, logFLine;

    ensureOperationHeader();
    const auto phase = event.phase.to!string;
    const auto now = Clock.currTime;
    const bool phaseChanged = phase != lastOperationPhase;
    if (haveProgress && !phaseChanged
        && now - lastProgress <= dur!"seconds"(1))
        return;

    if (operationProgressLineOpen)
    {
        logF("\r\x1b[K");
        operationProgressLineOpen = false;
    }

    const auto elapsed = operationStartedAt == SysTime.init
        ? Duration.zero : now - operationStartedAt;
    auto line = formatOperationProgressLine(event, terminalColumns(),
        supportsColor(), elapsed, true);
    logFLine("%s%s", formatTimestamp(now), line);
    lastProgress = now;
    haveProgress = true;
    lastOperationPhase = phase;
    lastOperationProgress = now;
    synchronized (operationStateMutex)
    {
        lastOperationEvent = event;
        haveLastOperationEvent = true;
    }
}

/** Clear the compact progress line before printing an operation summary. */
void clearOperationProgress()
{
    import dosierskanilo.logging : logF;

    if (operationProgressLineOpen)
        logF("\r\x1b[K");
    operationProgressLineOpen = false;
    lastOperationPhase = "";
    activeOperationControl = null;
    synchronized (operationStateMutex)
        operationHeartbeatActive = false;
}

@("formatOperationProgressLine reports phase, counts, timing, and path")
unittest
{
    OperationProgress event;
    event.phase = OperationPhase.checksums;
    event.completed = 24;
    event.total = 100;
    event.totalKnown = true;
    event.subtaskCompleted = 16 * 1024 * 1024;
    event.subtaskTotal = 32 * 1024 * 1024;
    event.subtaskTotalKnown = true;
    event.subtaskUnit = "bytes";
    event.path = "/library/films/A very long film filename.mkv";

    auto wide = formatOperationProgressLine(event, 100, false,
        dur!"seconds"(12), true);
    assert(wide.length <= 100, wide);
    assert(wide.canFind("checksums"), wide);
    assert(wide.canFind("24/100"), wide);
    assert(wide.canFind("16.0 MiB/32.0 MiB"), wide);
    assert(wide.canFind("filename.mkv"), wide);
    assert(wide.canFind("12s"), wide);
    assert(!wide.canFind("Catalog"), wide);

    auto narrow = formatOperationProgressLine(event, 60, false,
        dur!"seconds"(12));
    assert(narrow.length <= 60, narrow);
    assert(narrow.canFind("24/100"), narrow);

    auto veryNarrow = formatOperationProgressLine(event, 35, false,
        dur!"seconds"(12));
    assert(veryNarrow.length <= 35, veryNarrow);

    event.state = OperationState.cancelling;
    auto cancelled = formatOperationProgressLine(event, 100, false,
        dur!"seconds"(12), true);
    assert(cancelled.canFind("cancelling"), cancelled);
    assert(cancelled.canFind("checksums"), cancelled);
}

@("formatOperationProgressLine shows unknown-total progress and paths")
unittest
{
    OperationProgress event;
    event.phase = OperationPhase.scanning;
    event.completed = 1234567;
    event.path = "/library/films/A very long film filename.mkv";

    auto line = formatOperationProgressLine(event, 100);
    assert(line.canFind("1,234,567 items"), line);
    assert(line.canFind("filename.mkv"), line);
    assert(line.length <= 100, line);
}

/** Print scan progress on a single console line.
 *
 * This is the terminal renderer used by both the scanner and nested work
 * units.
 *
 * Params:
 *   idx = current position
 *   totalfiles = max position
 *   file = file we operate on or null
 *   subJob = optional subjob description
 */
void printProgress(size_t idx, size_t totalfiles, string file, string subJob = null)
{
    import dosierskanilo.logging : logF, logFLine;

    lastIdx = idx;
    lastTotalFiles = totalfiles;
    lastFile = file;

    const auto now = Clock.currTime;
    const bool tty = stdoutIsTerminal();
    if (lastProgress != SysTime.init)
    {
        const auto interval = tty ? dur!"seconds"(1) : dur!"seconds"(5);
        if (idx != 0 && now - lastProgress < interval)
            return;
    }

    const auto columns = terminalColumns();
    auto line = format("%s/%s", formatProgressCount(idx),
        formatProgressCount(totalfiles));
    if (!subJob.empty)
        line ~= "  " ~ subJob;
    if (!file.empty)
    {
        const available = columns > line.length + 1
            ? columns - line.length - 1 : 0;
        if (available > 0)
        {
            auto visible = file;
            if (visible.length > available)
                visible = shortenMiddle(visible, available).to!string;
            line ~= " " ~ visible;
        }
    }
    if (tty)
        logF("\r\x1b[K%s", line);
    else
        logFLine("%s%s", formatTimestamp(now), line);
    lastProgress = now;
}

@("printProgress")
unittest
{
    printProgress(0, 1000, "test/dummy-text-file.txt");
    printProgress(1, 1000, "test/dummy-text-file.txt");
    printProgress(10, 1000, "test/dummy-text-file.txt");
    printProgress(100, 1000, "test/dummy-text-file.txt");
    printProgress(1000, 1000, "test/dummy-text-file.txt");
    logLine("");
}
