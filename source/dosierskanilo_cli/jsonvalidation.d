/** Validation rules for the explicit direct JSON CLI workflow. */
module dosierskanilo_cli.jsonvalidation;

import std.file : exists, isDir, isFile;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate an explicit JSON command. */
bool validateJsonOptions(string command, ref ArgsArray options)
{
    if (!options.argExportJSON.empty || !options.argImportJSON.empty
        || options.argInitRepository || options.argShowInfo || options.argList
        || options.argDuplicates || options.argOutputFormat != "table"
        || options.argQueryLimit != 50 || options.argQueryOffset != 0
        || !options.argQueryText.empty || options.argQueryVideo
        || options.argQueryAudio || options.argQueryImage
        || options.argQueryTextStream || options.argQueryFileType
        || options.argQueryArchive || options.argQueryTorrent
        || options.argDuplicateLimit != 100)
    {
        errorLine("Repository query/transfer options are not valid in JSON mode.");
        return false;
    }

    if (command == "json-scan")
    {
        if (options.argDropMissing)
        {
            errorLine("--drop-missing is available only for JSON analyze or repository scan.");
            return false;
        }
        if (options.argScanPath.empty || !exists(options.argScanPath)
            || !isDir(options.argScanPath))
        {
            errorLine("JSON scan needs an existing directory ROOT.");
            return false;
        }
    }
    else if (command == "json-analyze" && (options.argRecursive
        || options.argPickHidden))
    {
        errorLine("--recursive and --pick-hidden are valid only for JSON scan.");
        return false;
    }
    if (options.argJSONFile.empty || !options.argJSONFile.endsWith(jsonFileExtension))
    {
        errorFLine("JSON catalog '%s' looks invalid.", options.argJSONFile);
        return false;
    }
    if (command == "json-analyze" && (!exists(options.argJSONFile)
        || !isFile(options.argJSONFile)))
    {
        errorFLine("JSON catalog '%s' does not exist.", options.argJSONFile);
        return false;
    }
    return true;
}
