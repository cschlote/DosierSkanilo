/** Command-line parsing and progress output helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo_cli.parser;

import std.conv;
import std.exception;
import std.getopt;
import std.file;
import std.path;
import std.process;
import std.range;
import std.string;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;
import dosierskanilo_cli.legacyvalidation : validateJsonOptions;
import dosierskanilo_cli.repositoryvalidation : validateRepositoryOptions;
import core.internal.lifetime;

immutable string helpText = q"EOS

This is a small utility to scan a directory and collect all files
found within. Each file with same size and same checksums are considered
the be the same.

It also utilizes the 'file' utility to determine filetypes, and can
calculate media signatures for audio and video files.

It can store its results in a JSON file, and read them back later on. It has
also some analysis functions to find duplicate files, missing files, etc.

The repository mode stores the current state in a `.dosierskanilo` SQLite
repository and keeps JSON available for import and export.

Commands:

    init       Initialize a repository
    scan       Scan a repository
    metadata   Extract metadata in a repository
    analyze    Analyze a repository
    info       Show repository information
    list       List repository blobs
    duplicates List duplicate blob groups
    import     Import JSON into a repository
    export     Export a repository as JSON

    json scan ROOT CATALOG.json
    json analyze CATALOG.json

EOS";

/** Top-level action selected by the command-line parser. */
enum CliCommand
{
    legacyJson,
    jsonScan,
    jsonAnalyze,
    init,
    scan,
    metadata,
    analyze,
    info,
    list,
    duplicates,
    importJson,
    exportJson
}

/** Result state of command-line parsing. */
enum ParseStatus
{
    run,
    help,
    showVersion,
    error
}

/** Parsed command-line state passed from the CLI entry point to its handlers. */
struct ParsedCommandLine
{
    ParseStatus status;
    CliCommand command;
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
    bool jsonMode;
    size_t commandIndex;
    ArgsArray argsarray;
    if (args.length > 1)
    {
        if (args[1] == "json")
        {
            if (args.length <= 2 || (args[2] != "scan" && args[2] != "analyze"))
            {
                errorLine("JSON mode requires 'scan' or 'analyze'.");
                return ParsedCommandLine(ParseStatus.error, CliCommand.legacyJson, argsarray);
            }
            jsonMode = true;
            command = args[2] == "scan" ? "json-scan" : "json-analyze";
            commandIndex = 2;
        }
        else
        {
            switch (args[1])
            {
            case "init", "scan", "metadata", "analyze", "info", "list",
                "duplicates", "import", "export":
                command = args[1];
                commandIndex = 1;
                break;
            default:
                break;
            }
        }
    }
    if (args.length <= 1)
        args ~= "--help"; // Show help, if no args given.

    string rootArgument;
    string catalogArgument;
    size_t positionalCount;
    auto positionalStart = commandIndex + 1;
    if (!command.empty && args.length > positionalStart
        && !args[positionalStart].startsWith("-"))
    {
        if (jsonMode && command == "json-scan")
        {
            rootArgument = args[positionalStart];
            positionalCount = 1;
            if (args.length > positionalStart + 1
                && !args[positionalStart + 1].startsWith("-"))
            {
                catalogArgument = args[positionalStart + 1];
                positionalCount = 2;
            }
        }
        else if (jsonMode && command == "json-analyze")
        {
            catalogArgument = args[positionalStart];
            positionalCount = 1;
        }
        else if (command == "export")
        {
            rootArgument = args[positionalStart];
            positionalCount = 1;
        }
        else if (command == "import")
        {
            catalogArgument = args[positionalStart];
            positionalCount = 1;
            if (args.length > positionalStart + 1
                && !args[positionalStart + 1].startsWith("-"))
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
        args = args[0 .. commandIndex]
            ~ args[commandIndex + 1 + positionalCount .. $];
    }
    if (!rootArgument.empty)
    {
        if (jsonMode)
            argsarray.argScanPath = rootArgument;
        else
            argsarray.argRepositoryPath = rootArgument;
    }
    if (!catalogArgument.empty)
        argsarray.argJSONFile = catalogArgument;

    /* Parse the commandline with std.getopt */
    GetoptResult helpInformation;
    try
    {
        helpInformation = getopt(args, /* std.getopt.config.required, */

            "output", "Output JSON file for export", &argsarray.argExportJSON,
            "recursive", "Recursively scan directories", &argsarray.argRecursive,
            "checksums", "Calculate the checksums", &argsarray.argDoChecksums,
            "file-types", "Query file type with 'file' utility", &argsarray.argDoFileTypes,
            "media-info", "Calculate the media signature", &argsarray.argDoMediaSig,
            "rescan-media-info", "Rescan all files for media signature", &argsarray.argRescanMediaSig,
            "scan-archives", "Get the contents of archives", &argsarray.argScanArchivesOption,
            "scan-torrents", "Get the contents of torrent files", &argsarray.argScanTorrents,
            "drop-missing", "Drop missing files from database", &argsarray.argDropMissing,
            "threads", "Number of worker threads", &argsarray.argNumberOfThreads,
            "replace", "Replace an existing repository catalog on import", &argsarray.argReplaceCatalog,
            "pick-hidden", "Pick hidden files and directories too", &argsarray.argPickHidden,
            "verbose", "Be verbose", &argsarray.argVerboseOutputs,
            "text", "Filter repository paths or SHA1 values", &argsarray.argQueryText,
            "limit", "Maximum number of listed repository blobs", &argsarray.argQueryLimit,
            "offset", "Number of matching repository blobs to skip", &argsarray.argQueryOffset,
            "video", "Require video metadata", &argsarray.argQueryVideo,
            "audio", "Require audio metadata", &argsarray.argQueryAudio,
            "image", "Require image metadata", &argsarray.argQueryImage,
            "text-stream", "Require text or subtitle metadata", &argsarray.argQueryTextStream,
            "file-type", "Require file type metadata", &argsarray.argQueryFileType,
            "archive", "Require archive metadata", &argsarray.argQueryArchive,
            "torrent", "Require torrent metadata", &argsarray.argQueryTorrent,
            "duplicate-limit", "Maximum number of duplicate groups", &argsarray.argDuplicateLimit,
            "format", "Repository query output format: table or json", &argsarray.argOutputFormat,
            "version", "Show the application version", &argsarray.argVersion);
    }
    catch (GetOptException ex)
    {
        errorLine("Invalid command-line arguments: ", ex.msg);
        errorLine("Use --help to see the available options.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.legacyJson, argsarray);
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
    case "list":
        argsarray.argList = true;
        break;
    case "duplicates":
        argsarray.argDuplicates = true;
        break;
    case "analyze":
        argsarray.argRunAnalysis = true;
        break;
    case "json-scan":
        argsarray.argScanFiles = true;
        argsarray.argWriteJSON = true;
        break;
    case "json-analyze":
        argsarray.argRunAnalysis = true;
        argsarray.argWriteJSON = true;
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
	if (argsarray.argScanArchivesOption && argsarray.argScanArchives == 0)
		argsarray.argScanArchives = 1;

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
        return ParsedCommandLine(ParseStatus.help, CliCommand.legacyJson, argsarray);
    }
    if (argsarray.argVersion)
        return ParsedCommandLine(ParseStatus.showVersion, CliCommand.legacyJson, argsarray);

    setVerboseOutputs(argsarray.argVerboseOutputs);
    if (command.empty)
    {
        errorLine("Choose a command. Use --help to see available commands.");
        return ParsedCommandLine(ParseStatus.error, CliCommand.legacyJson, argsarray);
    }

    if (jsonMode)
    {
        if (!validateJsonOptions(command, argsarray))
            return ParsedCommandLine(ParseStatus.error, CliCommand.legacyJson, argsarray);
        return ParsedCommandLine(ParseStatus.run, commandToCliCommand(command), argsarray);
    }

    if (!validateRepositoryOptions(command, argsarray))
        return ParsedCommandLine(ParseStatus.error, CliCommand.legacyJson, argsarray);
    return ParsedCommandLine(ParseStatus.run, commandToCliCommand(command), argsarray);
}

/** Map a recognized command token to its typed action. */
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
    case "list":
        return CliCommand.list;
    case "duplicates":
        return CliCommand.duplicates;
    case "analyze":
        return CliCommand.analyze;
    case "json-scan":
        return CliCommand.jsonScan;
    case "json-analyze":
        return CliCommand.jsonAnalyze;
    case "import":
        return CliCommand.importJson;
    case "export":
        return CliCommand.exportJson;
    case "":
        return CliCommand.legacyJson;
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

    auto jsonScan = parseCommandLine(["programname", "json", "scan", root,
        catalog, "--recursive"]);
    assert(jsonScan.status == ParseStatus.run);
    assert(jsonScan.command == CliCommand.jsonScan);
    assert(jsonScan.options.argScanPath == root);
    assert(jsonScan.options.argJSONFile == catalog);
    assert(jsonScan.options.argScanFiles);
    assert(jsonScan.options.argWriteJSON);

    auto jsonAnalyze = parseCommandLine(["programname", "json", "analyze",
        "./test/json_file_v2.json"]);
    assert(jsonAnalyze.status == ParseStatus.run);
    assert(jsonAnalyze.command == CliCommand.jsonAnalyze);
    assert(jsonAnalyze.options.argRunAnalysis);
    assert(jsonAnalyze.options.argWriteJSON);
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
    assert(s1.startsWith("- 0.000000"), s1);
    auto s2 = makeProgressString(50, 100);
    assert(s2.startsWith("\\ 0.500000"), s2);
    auto s3 = makeProgressString(100, 100);
    assert(s3.startsWith("| 1.000000"), s3);
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

SysTime lastProgress;
size_t lastIdx;
size_t lastTotalFiles;
string lastFile;

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
    enum EL0 = "\x1b[K"; // Delete to end of line, to clear the line after the progress output

    lastIdx = idx;
    lastTotalFiles = totalfiles;
    lastFile = file;

    if (file.empty || idx == 0)
    {
        lastProgress = Clock.currTime;
    }
    Duration lastDelta = Clock.currTime - lastProgress;
    bool itsTime = lastDelta > dur!"seconds"(1);
    if (file.empty || idx == 0 || itsTime)
    {
        enum fnfsz = 66;
        auto fileEclipsed = shortenMiddle(file, fnfsz);
        assert(fileEclipsed.length <= fnfsz, "clip: " ~ fileEclipsed.length.text);
        fileEclipsed = padLeft(fileEclipsed, fnfsz);
        try
        {
            logF("\r%6d/%6d:%10s:%s" ~ EL0, idx, totalfiles, subJob, fileEclipsed[$ - fnfsz .. $]);
        }
        catch (Exception ex)
        {
            logLine("\n");
            logFLine("Catched exception: %s\nFile: %s", ex.msg, file);
            //assert(false, ex.msg);
        }
        lastProgress = Clock.currTime;
    }
    else
    {
        //writeln("Boooh");
    }
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
