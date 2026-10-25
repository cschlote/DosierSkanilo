/** Validation rules for the explicit direct JSON CLI workflow. */
module dosierskanilo_cli.jsonvalidation;

import std.file : exists, isDir, isFile, remove, tempDir, write;
import std.path : buildPath;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate a JSON-target scan, analysis, list, or duplicate command. */
bool validateJsonOptions(string command, ref ArgsArray options)
{
    if (options.argJSONFile.empty || !options.argJSONFile.endsWith(jsonFileExtension))
    {
        errorFLine("JSON catalog '%s' looks invalid.", options.argJSONFile);
        return false;
    }
    if (options.argBaseDir.empty)
        options.argBaseDir = ".";

    if (command != "scan" && options.argMergeDuplicates)
    {
        errorLine("--merge-duplicates is available only for JSON scan.");
        return false;
    }

    if ((command == "analyze" || command == "list" || command == "duplicates")
        && (!exists(options.argJSONFile) || !isFile(options.argJSONFile)))
    {
        errorFLine("JSON catalog '%s' does not exist.", options.argJSONFile);
        return false;
    }

    switch (command)
    {
    case "scan":
    case "analyze":
        if (!options.argExportJSON.empty || !options.argImportJSON.empty
            || options.argInitRepository || options.argShowInfo
            || options.argList || options.argDuplicates
            || options.argOutputFormat != "table"
            || options.argQueryLimit != 50 || options.argQueryOffset != 0
            || !options.argQueryText.empty || options.argQueryVideo
            || options.argQueryAudio || options.argQueryImage
            || options.argQueryTextStream || options.argQueryFileType
            || options.argQueryArchive || options.argQueryTorrent
            || options.argDuplicateLimit != 100)
        {
            errorLine("Repository query/transfer options are not valid in JSON scan or analysis.");
            return false;
        }

        if (command == "scan")
        {
            if (options.argDropMissing)
            {
                errorLine("--drop-missing is available only for JSON analyze or repository scan.");
                return false;
            }
            if (!exists(options.argBaseDir) || !isDir(options.argBaseDir))
            {
                errorLine("JSON scan needs an existing base directory.");
                return false;
            }
        }
        else if (options.argRecursive || options.argPickHidden)
        {
            errorLine("--recursive and --pick-hidden are valid only for JSON scan.");
            return false;
        }
        if (command == "analyze" && (!exists(options.argJSONFile)
            || !isFile(options.argJSONFile)))
        {
            errorFLine("JSON catalog '%s' does not exist.", options.argJSONFile);
            return false;
        }
        return true;

    case "list":
        if (!options.argExportJSON.empty || !options.argImportJSON.empty
            || options.argInitRepository || options.argShowInfo
            || options.argDuplicates || options.argDropMissing
            || options.argMergeDuplicates || options.argDryRun
            || options.argRecursive || options.argPickHidden
            || options.argDoChecksums || options.argDoFileTypes
            || options.argDoMediaSig || options.argScanArchives
            || options.argScanTorrents || options.argRescanMediaSig
            || options.argDuplicateLimit != 100)
        {
            errorLine("JSON list supports only query filters and --format.");
            return false;
        }
        return true;

    case "duplicates":
        if (!options.argExportJSON.empty || !options.argImportJSON.empty
            || options.argInitRepository || options.argShowInfo
            || options.argList || options.argDropMissing
            || options.argMergeDuplicates || options.argDryRun
            || options.argRecursive || options.argPickHidden
            || options.argDoChecksums || options.argDoFileTypes
            || options.argDoMediaSig || options.argScanArchives
            || options.argScanTorrents || options.argRescanMediaSig
            || !options.argQueryText.empty || options.argQueryLimit != 50
            || options.argQueryOffset != 0 || options.argQueryVideo
            || options.argQueryAudio || options.argQueryImage
            || options.argQueryTextStream || options.argQueryFileType
            || options.argQueryArchive || options.argQueryTorrent)
        {
            errorLine("JSON duplicate queries support only --format and --duplicate-limit.");
            return false;
        }
        return true;

    default:
        errorLine("JSON mode supports scan, analyze, list, and duplicates.");
        return false;
    }
}

@("validateJsonOptions")
unittest
{
    auto baseDir = tempDir();

    auto scanOptions = ArgsArray();
    scanOptions.argJSONFile = buildPath(baseDir, "catalog.json");
    scanOptions.argBaseDir = baseDir;
    assert(validateJsonOptions("scan", scanOptions));

    auto analyzeOptions = ArgsArray();
    analyzeOptions.argJSONFile = buildPath(baseDir, "catalog.json");
    write(analyzeOptions.argJSONFile, "[]");
    scope (exit)
        if (exists(analyzeOptions.argJSONFile))
            remove(analyzeOptions.argJSONFile);
    assert(validateJsonOptions("analyze", analyzeOptions));
    assert(analyzeOptions.argBaseDir == ".");

    auto invalidAnalyze = ArgsArray();
    invalidAnalyze.argJSONFile = analyzeOptions.argJSONFile;
    invalidAnalyze.argRecursive = true;
    assert(!validateJsonOptions("analyze", invalidAnalyze));
}
