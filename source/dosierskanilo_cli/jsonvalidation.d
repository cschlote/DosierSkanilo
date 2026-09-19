/** Validation rules for the explicit direct JSON CLI workflow. */
module dosierskanilo_cli.jsonvalidation;

import std.file : exists, isDir, isFile;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate an explicit JSON command. */
bool validateJsonOptions(string command, ref ArgsArray options)
{
    if (command == "json-scan")
    {
        if (options.argScanPath.empty || !exists(options.argScanPath)
            || !isDir(options.argScanPath))
        {
            errorLine("JSON scan needs an existing directory ROOT.");
            return false;
        }
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
