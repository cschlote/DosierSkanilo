/** Validation rules for SQLite repository CLI commands. */
module dosierskanilo_cli.repositoryvalidation;

import std.file : exists, isDir;
import std.string : empty, endsWith;

import dosierskanilo;
import dosierskanilo_cli.logging : errorFLine, errorLine;

/** Validate repository target, command options, and transfer filenames. */
bool validateRepositoryOptions(string command, ref ArgsArray options)
{
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
            ~ "--checksum, --filetypes, --mediasig, --scanArchives, "
            ~ "or --scanTorrents.");
        return false;
    }
    if ((command == "info" || command == "list" || command == "duplicates")
        && options.argOutputFormat != "table"
        && options.argOutputFormat != "json")
    {
        errorLine("Repository query format must be 'table' or 'json'.");
        return false;
    }
    if (!validateRepositoryCommand(command, options))
        return false;
    if (!options.argImportJSON.empty && !options.argImportJSON.endsWith(jsonFileExtension))
    {
        errorFLine("Import JSON filename '%s' looks invalid.", options.argImportJSON);
        return false;
    }
    if (!options.argExportJSON.empty && !options.argExportJSON.endsWith(jsonFileExtension))
    {
        errorFLine("Export JSON filename '%s' looks invalid.", options.argExportJSON);
        return false;
    }
    return true;
}

private bool hasMetadataOptions(ArgsArray options)
{
    return options.argDoChecksums || options.argDoFileTypes
        || options.argDoMediaSig || options.argScanArchives
        || options.argScanTorrents;
}

private bool validateRepositoryCommand(string command, ArgsArray options)
{
    bool hasStorageAction = options.argInitRepository || options.argScanFiles
        || options.argRunMetadata || options.argRunAnalysis
        || !options.argImportJSON.empty || !options.argExportJSON.empty
        || options.argWriteJSON;
    bool hasMetadataAction = options.argDoChecksums || options.argDoFileTypes
        || options.argDoMediaSig || options.argScanArchives
        || options.argScanTorrents;

    final switch (command)
    {
    case "info":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "list", "duplicates":
        if (hasStorageAction || hasMetadataAction || options.argDropMissing
            || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "metadata":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunAnalysis || !options.argImportJSON.empty
            || !options.argExportJSON.empty || options.argWriteJSON
            || options.argDropMissing || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "analyze", "analyse":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || hasMetadataAction
            || !options.argImportJSON.empty || !options.argExportJSON.empty
            || options.argWriteJSON || options.argReplaceCatalog)
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
            || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "import":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || hasMetadataAction || options.argDropMissing || options.argWriteJSON)
            return invalidCommandOptions(command);
        break;
    case "export":
        if (options.argInitRepository || options.argScanFiles
            || options.argRunMetadata || options.argRunAnalysis
            || hasMetadataAction || options.argDropMissing || options.argWriteJSON
            || options.argReplaceCatalog)
            return invalidCommandOptions(command);
        break;
    case "":
        break;
    }
    return true;
}

private bool invalidCommandOptions(string command)
{
    errorFLine("Options are not valid for the '%s' command.", command);
    errorLine("Use --help to see the options supported by this command.");
    return false;
}
