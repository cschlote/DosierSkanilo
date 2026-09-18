/** Validation rules for the compatibility JSON CLI workflow. */
module dosierskanilo_cli.legacyvalidation;

import std.file : exists, isDir;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate the option-only direct JSON workflow. */
bool validateLegacyOptions(ref ArgsArray options)
{
    if (options.argScanPath.empty)
    {
        errorLine("We need a scan path. Use -p to specify it.");
        return false;
    }
    if (!exists(options.argScanPath))
    {
        errorFLine("We need a directory for the scan path. '%s' doesn't even exist.",
            options.argScanPath);
        return false;
    }
    if (!isDir(options.argScanPath))
    {
        errorFLine("We need a directory for the scan path. '%s' is not a directory.",
            options.argScanPath);
        return false;
    }
    if (options.argJSONFile.empty || !options.argJSONFile.endsWith(jsonFileExtension))
    {
        errorFLine("JSON filename '%s' looks invalid.", options.argJSONFile);
        errorLine("We expect a filename here, not a path.");
        errorLine("We expect the \"" ~ jsonFileExtension ~ "\" file extension.");
        return false;
    }
    if (options.argJSONFile.exists)
    {
        errorLine("JSON file '", options.argJSONFile, "' exists.");
        if (options.argWriteJSON)
        {
            if (options.argForceOverwrite)
                errorLine("Force overwriting of existing JSON file.");
            else
            {
                errorLine("Abort program. Use -f to force overwriting of output file.");
                return false;
            }
        }
    }
    return true;
}
