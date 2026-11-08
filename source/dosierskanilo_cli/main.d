/** Main application module for directory scanning and metadata extraction.
 *
 * The purpose of this module is to scan a directory (or a tree) and to calculate
 * hashes on file contents. Optionally it detects media metadata, archive
 * contents, and torrent metadata.
 *
 * The information can be saved to a JSON file. On future runs
 * this information can be read again. New paths are added to existing entries.
 *
 * Note:
 *   XML file support was removed. It resulted in much larger files, was very slow
 *   to read and write. This is true for 'orange' at least. Other XML serializers
 *   might be faster, but won't solve the basic size problem compared especially
 *   when compared to the JSON output.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo_cli.main;

/* ----------------------------------------------------------------------- */

import core.atomic : atomicLoad, atomicStore;
import core.stdc.signal;

import std.algorithm.iteration;
import std.array;
import std.conv;
import std.datetime.systime;
import std.datetime.timezone;
import std.exception;
import std.file;
import std.getopt;
import std.parallelism;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;
import std.utf;

import dosierskanilo;
import dosierarkivo;

import dosierskanilo_cli.parser;
import dosierskanilo_cli.logging : errorFLine, errorLine, noticeFLine;
import dosierskanilo.operationrunner : runOperation;

version (ldc)
{
	import ldc.eh_msvc;
}

/* ----------------------------------------------------------------------- */

/* The global wrapper with all file objects and shared metadata */
/* Custom CTRL-C handler for a smooth abort of running scan operation */
shared bool gotCtrlC; /// Set in handler

/* Some constants */
/** User-facing application name used in help text and log messages. */
immutable string appName = "DosierSkanilo";
/** Build version embedded from the generated `build-version.txt` at compile time. */
immutable string appVersion = import("build/bin/build-version.txt").strip;

/** Main Entry
 *
 * Decode command-line parameters and run the scanner workflow.
 * When unit testing, do nothing.
 *
 * Exit codes: 0 success, 1 operation failure, 2 usage error (parse
 * failure or invalid option combination).
 *
 * Params:
 *   args = command-line arguments
 * Returns:
 *   shell code: 0 success, 1 operation failure, 2 usage error
 */
int main(string[] args)
{
	version (unittest)
	{
		logLine("Entered main() in Unittest Mode. Do nothing.");
		return 0;
	}
	else
	{
		auto parsed = parseCommandLine(args);
		final switch (parsed.status)
		{
		case ParseStatus.help:
			return 0;
		case ParseStatus.showVersion:
			logFLine("%s %s", appName, appVersion);
			return 0;
		case ParseStatus.error:
			return 2;
		case ParseStatus.run:
			auto options = parsed.options;
			if (!configureArchiveCache(options))
				return 1;
			noticeFLine("%s %s", appName, appVersion);
			printRunSettings(options, parsed.command);
			if (options.argDoMediaSig && options.argVerboseOutputs)
			{
				auto miv = getMediaInfoVersion();
				noticeFLine("Using %s", miv);
			}
			const auto oldhandler = signal(SIGINT, &signalHandler);
			if (oldhandler == SIG_ERR)
				logLine("Warning: could not install the SIGINT handler.");
			scope (exit)
				if (oldhandler != SIG_ERR)
					signal(SIGINT, oldhandler);

			bool rc;
			try
			{
				if (parsed.command == CliCommand.recover)
					rc = executeCatalogRecovery(options);
				else if (parsed.command == CliCommand.scan
					|| parsed.command == CliCommand.analyze)
					rc = executeCatalogOperation(options);
				else
					rc = executeRepositoryOperation(options);
			}
			catch (Exception ex)
			{
				clearOperationProgress();
				errorLine("Operation failed: ", ex.msg);
				if (isVerboseOutputs())
					errorLine(ex.toString());
				return 1;
			}
			return rc ? 0 : 1;
		}
	}
}

/** Human-readable command name for startup diagnostics.
 *
 * Params:
 *     command = Parsed CLI command.
 * Returns: The lowercase command word, or an empty string for
 *     `CliCommand.noCommand`.
 */
private string commandDisplayName(CliCommand command)
{
	final switch (command)
	{
	case CliCommand.noCommand:
		return "";
	case CliCommand.init:
		return "init";
	case CliCommand.scan:
		return "scan";
	case CliCommand.metadata:
		return "metadata";
	case CliCommand.analyze:
		return "analyze";
	case CliCommand.info:
		return "info";
	case CliCommand.list:
		return "list";
	case CliCommand.duplicates:
		return "duplicates";
	case CliCommand.importJson:
		return "import";
	case CliCommand.exportJson:
		return "export";
	case CliCommand.recover:
		return "recover";
	}
}

/** Primary path shown in startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 *     command = Command whose direction of transfer or target should be shown.
 * Returns: A display path or `source -> destination` description; `"."` is
 *     used when no path was supplied.
 */
private string settingsTarget(ArgsArray options, CliCommand command)
{
	const auto repository = options.argRepositoryPath.empty
		? options.argScanPath : options.argRepositoryPath;
	final switch (command)
	{
	case CliCommand.importJson:
		return (options.argImportJSON.empty ? "(missing)"
			: options.argImportJSON) ~ " -> "
			~ (repository.empty ? "." : repository);
	case CliCommand.exportJson:
		return (repository.empty ? "." : repository) ~ " -> "
			~ (options.argExportJSON.empty ? "(missing)"
				: options.argExportJSON);
	case CliCommand.recover:
		return options.argJSONFile.empty ? "(missing)" : options.argJSONFile;
	case CliCommand.noCommand, CliCommand.init, CliCommand.scan,
		CliCommand.metadata, CliCommand.analyze, CliCommand.info,
		CliCommand.list, CliCommand.duplicates:
		break;
	}
	if (!options.argJSONFile.empty)
		return options.argBaseDir.empty || options.argBaseDir == "."
			? options.argJSONFile
			: options.argJSONFile ~ " (base " ~ options.argBaseDir ~ ")";
	if (!options.argRepositoryPath.empty)
		return options.argRepositoryPath;
	if (!options.argScanPath.empty)
		return options.argScanPath;
	return ".";
}

/** Storage mode shown in startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 *     command = Command being executed.
 * Returns: `"repository"` or `"JSON"`.
 */
private string settingsStorage(ArgsArray options, CliCommand command)
{
	if (command == CliCommand.importJson)
		return "repository";
	if (command == CliCommand.exportJson || command == CliCommand.recover)
		return "JSON";
	return options.argJSONFile.empty ? "repository" : "JSON";
}

/** Active metadata extractor labels for startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: Labels for the enabled extractors in display order; empty when no
 *     metadata option is enabled.
 */
private string[] metadataSettings(ArgsArray options)
{
	string[] labels;
	if (options.argDoChecksums)
		labels ~= "checksums";
	if (options.argDoFileTypes)
		labels ~= "file types";
	if (options.argDoMediaSig)
		labels ~= "media info";
	if (options.argRescanMediaSig)
		labels ~= "media rescan";
	if (options.argScanArchives == 1)
		labels ~= "archives shallow";
	else if (options.argScanArchives > 1)
		labels ~= "archives deep";
	if (options.argScanTorrents)
		labels ~= "torrents";
	return labels;
}

/** Active scan/analysis/runtime labels for startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 *     command = Command being executed; scan-specific labels are omitted for
 *         other commands.
 * Returns: Labels such as recursion mode, hidden-file handling, drop-missing
 *     and thread count; empty when nothing applies.
 */
private string[] scopeSettings(ArgsArray options, CliCommand command)
{
	string[] labels;
	if (command == CliCommand.scan)
	{
		labels ~= options.argRecursive ? "recursive" : "top-level";
		if (options.argPickHidden)
			labels ~= "hidden included";
	}
	if ((command == CliCommand.scan || command == CliCommand.analyze)
		&& options.argDropMissing)
		labels ~= "drop missing";
	if (options.argNumberOfThreads > 1)
		labels ~= options.argNumberOfThreads.to!string ~ " threads";
	return labels;
}

/** Active output/JSON flags for startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: Labels for enabled flags in display order; empty when none apply.
 */
private string[] flagSettings(ArgsArray options)
{
	string[] labels;
	if (options.argDryRun)
		labels ~= "dry-run";
	if (options.argMergeDuplicates)
		labels ~= "merge duplicates";
	if (options.argPrettyJSON)
		labels ~= "pretty";
	if (options.argReplaceCatalog)
		labels ~= "replace";
	if (options.argNoInput)
		labels ~= "no input";
	return labels;
}

/** Active query settings for list/duplicate commands.
 *
 * Params:
 *     options = Parsed command-line options.
 *     command = Command being executed; other commands yield no labels.
 * Returns: Query labels such as text, limit, offset, media requirements and
 *     output format; empty for commands without query settings.
 */
private string[] querySettings(ArgsArray options, CliCommand command)
{
	if (command != CliCommand.list && command != CliCommand.duplicates)
		return [];
	string[] labels;
	if (!options.argQueryText.empty)
		labels ~= "text=" ~ options.argQueryText;
	if (options.argQueryLimit != 50)
		labels ~= "limit=" ~ options.argQueryLimit.to!string;
	if (options.argQueryOffset != 0)
		labels ~= "offset=" ~ options.argQueryOffset.to!string;
	string[] media;
	if (options.argQueryVideo) media ~= "video";
	if (options.argQueryAudio) media ~= "audio";
	if (options.argQueryImage) media ~= "image";
	if (options.argQueryTextStream) media ~= "text";
	if (options.argQueryFileType) media ~= "file-type";
	if (options.argQueryArchive) media ~= "archive";
	if (options.argQueryTorrent) media ~= "torrent";
	if (media.length > 0)
		labels ~= "require " ~ media.join(",");
	labels ~= "format=" ~ options.argOutputFormat;
	return labels;
}

/** Describe the archive cache for verbose startup diagnostics.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: The configured directory and optional MiB limit, or `"default"`
 *     when no cache option was supplied.
 */
private string archiveCacheSetting(ArgsArray options)
{
	if (!options.argArchiveCacheDir.empty)
		return options.argArchiveCacheDir
			~ (options.argArchiveCacheMiB > 0
				? " (" ~ options.argArchiveCacheMiB.to!string ~ " MiB)"
				: "");
	if (options.argArchiveCacheMiB > 0)
		return "default directory (" ~ options.argArchiveCacheMiB.to!string
			~ " MiB)";
	return "default";
}

/** Print the active settings before any MediaInfo version banner.
 *
 * Compact mode emits one line so redirected logs stay small. Verbose mode
 * expands the same values into labelled lines.
 *
 * Params:
 *     options = Parsed command-line options.
 *     command = Command being executed.
 */
private void printRunSettings(ArgsArray options, CliCommand command)
{
	const auto name = commandDisplayName(command);
	const auto target = settingsTarget(options, command);
	const auto storage = settingsStorage(options, command);
	const auto metadata = metadataSettings(options);
	const auto scopeLabels = scopeSettings(options, command);
	const auto flags = flagSettings(options);
	const auto query = querySettings(options, command);

	if (!options.argVerboseOutputs)
	{
		string[] parts = [name ~ " " ~ target ~ " (" ~ storage ~ ")"];
		if (scopeLabels.length > 0)
			parts ~= scopeLabels.join(", ");
		parts ~= (metadata.length > 0
			? "metadata: " ~ metadata.join(", ") : "metadata: none");
		if (flags.length > 0)
			parts ~= flags.join(", ");
		if (query.length > 0)
			parts ~= query.join(", ");
		noticeFLine("Settings: %s", parts.join("; "));
		return;
	}

	noticeFLine("Settings:");
	noticeFLine("  command: %s", name);
	noticeFLine("  target: %s", target);
	noticeFLine("  storage: %s", storage);
	noticeFLine("  scope: %s", scopeLabels.length > 0
		? scopeLabels.join(", ") : "default");
	noticeFLine("  metadata: %s",
		metadata.length > 0 ? metadata.join(", ") : "none");
	noticeFLine("  workers: %d", options.argNumberOfThreads);
	noticeFLine("  archive cache: %s", archiveCacheSetting(options));
	if (flags.length > 0)
		noticeFLine("  flags: %s", flags.join(", "));
	if (query.length > 0)
		noticeFLine("  query: %s", query.join(", "));
}

/** List backups/recovery files for one catalog and optionally restore one.
 *
 * Backup and recovery files are searched next to the catalog, in the XDG state
 * directory and in the system temporary directory. With `--restore-from`, the
 * current catalog is backed up before the selected file is copied into place.
 *
 * Params:
 *     options = Parsed command-line options providing the catalog path and the
 *         optional restore source.
 * Returns: `true` on success (including a listing-only invocation); `false`
 *     after logging an error when the catalog path is missing, the restore
 *     source is invalid, or the restore fails.
 */
bool executeCatalogRecovery(ArgsArray options)
{
	import dosierskanilo.model.namedbinaryblob :
		deserializeDataClassJsonWrapperFile;
	import std.algorithm.sorting : sort;
	import std.file : SpanMode, copy, dirEntries, exists, isFile, mkdirRecurse,
		remove, rename, tempDir, timeLastModified;
	import std.path : baseName, buildPath, dirName;
	import std.process : environment;
	import std.uuid : randomUUID;

	const catalog = options.argJSONFile;
	if (catalog.empty)
	{
		errorFLine("recover requires a JSON catalog path.");
		return false;
	}
	const name = baseName(catalog);
	const stem = name.length > jsonFileExtension.length
		&& name[$ - jsonFileExtension.length .. $] == jsonFileExtension
		? name[0 .. $ - jsonFileExtension.length] : name;

	string[] directories = [dirName(catalog)];
	auto stateHome = environment.get("XDG_STATE_HOME", "");
	if (stateHome.empty)
	{
		const home = environment.get("HOME", "");
		if (!home.empty)
			stateHome = buildPath(home, ".local", "state");
	}
	if (!stateHome.empty)
		directories ~= buildPath(stateHome, "dosierskanilo", "recovery");
	directories ~= tempDir();

	string[] candidates;
	foreach (directory; directories)
	{
		if (!exists(directory))
			continue;
		foreach (entry; dirEntries(directory, SpanMode.shallow))
		{
			if (!isFile(entry.name))
				continue;
			const candidateName = baseName(entry.name);
			if (candidateName.startsWith(stem ~ "-")
				|| candidateName.startsWith(stem ~ jsonFileExtension ~ ".tmp-"))
				candidates ~= entry.name;
		}
	}
	candidates.sort;

	noticeFLine("Catalog: %s", catalog);
	if (candidates.length == 0)
		logLine("No backups or recovery files found.");
	foreach (candidate; candidates)
	{
		bool valid;
		size_t entries;
		string errorMessage;
		try
		{
			const loaded = deserializeDataClassJsonWrapperFile(candidate);
			entries = loaded.dataArray.length;
			valid = true;
		}
		catch (Exception ex)
			errorMessage = ex.msg;
		logFLine("%s %s", valid ? "valid  " : "invalid", candidate);
		if (valid)
			logLine("    entries: %s", entries);
		else
			logLine("    %s", errorMessage);
	}

	if (options.argRestoreFrom.empty)
		return true;

	const restoreFrom = options.argRestoreFrom;
	if (!exists(restoreFrom))
	{
		errorFLine("Recovery file does not exist: %s", restoreFrom);
		return false;
	}
	try
		deserializeDataClassJsonWrapperFile(restoreFrom);
	catch (Exception ex)
	{
		errorFLine("Recovery file is not a valid catalog: %s", ex.msg);
		return false;
	}

	if (!exists(dirName(catalog)))
		mkdirRecurse(dirName(catalog));
	if (exists(catalog))
	{
		const backup = catalog ~ ".before-restore-"
			~ Clock.currTime.toISOExtString.replace(":", "-");
		copy(catalog, backup);
		logFLine("Backed up current catalog to '%s'.", backup);
	}
	const staging = catalog ~ ".restore-" ~ randomUUID().toString();
	try
	{
		copy(restoreFrom, staging);
		version (Windows)
			if (exists(catalog))
				remove(catalog);
		rename(staging, catalog);
	}
	catch (Exception ex)
	{
		if (exists(staging))
		{
			try
				remove(staging);
			catch (Exception)
			{
			}
		}
		errorFLine("Could not restore the catalog: %s", ex.msg);
		return false;
	}
	noticeFLine("Restored '%s' from '%s'.", catalog, restoreFrom);
	return true;
}

/** Configure the shared archive member cache from CLI options.
 *
 * Does nothing when neither a cache directory nor a size limit was requested.
 * A requested size limit is converted from MiB to bytes; zero keeps the default
 * byte limit.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: `true` when the cache is configured or no cache was requested;
 *     `false` after logging an error when configuration fails.
 */
private bool configureArchiveCache(ArgsArray options)
{
	import dosierskanilo.membercontentcache :
		configureSharedMemberContentCache, defaultMemberCacheByteLimit;

	if (options.argArchiveCacheDir.empty && options.argArchiveCacheMiB == 0)
		return true;
	ulong byteLimit = defaultMemberCacheByteLimit;
	if (options.argArchiveCacheMiB > 0)
		byteLimit = cast(ulong) options.argArchiveCacheMiB * 1_048_576UL;
	try
	{
		configureSharedMemberContentCache(options.argArchiveCacheDir, byteLimit);
		return true;
	}
	catch (Exception ex)
	{
		errorFLine("Cannot configure archive cache: %s", ex.msg);
		return false;
	}
}

/** Execute a SQLite repository operation selected by the CLI options.
 *
 * Opens either the repository or a JSON-backed catalog and then dispatches to
 * info, list, duplicates, import, metadata and export steps as requested.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: `true` when every requested step succeeded; `false` after logging
 *     an error when a step fails.
 */
bool executeRepositoryOperation(ArgsArray options)
{
	Repository repository;
	CatalogBackend backend;
	string sourceRoot;
	scope (exit)
	{
		if (backend !is null)
			backend.close();
		if (repository !is null)
			repository.close();
	}
	try
	{
		if (options.argJSONFile.empty || !options.argImportJSON.empty)
		{
			auto repositoryPath = options.argRepositoryPath;
			if (repositoryPath.empty)
				repositoryPath = options.argScanPath;

			if (options.argInitRepository)
			{
				auto databaseAlreadyExists = exists(buildPath(repositoryPath,
					repositoryDirectoryName, repositoryDatabaseFileName));
				repository = Repository.initialize(repositoryPath,
					RepositoryOptions(), options.argForceInit);
				if (options.argForceInit && databaseAlreadyExists)
					logFLine("Reinitialized repository at '%s'.", repository.rootPath);
				else if (databaseAlreadyExists)
					logFLine("Opened existing repository at '%s'.", repository.rootPath);
				else
					logFLine("Initialized new repository at '%s'.", repository.rootPath);
			}
			else
				repository = Repository.open(repositoryPath);
			repository.appendLog("repository.open", repositoryPath);
			auto backendFactory = new DefaultCatalogBackendFactory;
			backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
			sourceRoot = repository.rootPath;
		}
		else
		{
			auto backendFactory = new DefaultCatalogBackendFactory;
			backend = backendFactory.open(OperationTarget.jsonTarget(options.argJSONFile,
				options.argBaseDir));
			sourceRoot = backend.repositoryInfo().rootPath;
		}
		if (options.argShowInfo)
		{
			executeRepositoryInfo(backend, sourceRoot, options);
			return true;
		}
		if (options.argList)
		{
			executeRepositoryList(backend, sourceRoot, options);
			return true;
		}
		if (options.argDuplicates)
		{
			executeRepositoryDuplicates(backend, sourceRoot, options);
			return true;
		}

		if (!options.argImportJSON.empty
			&& !executeRepositoryImport(backend, sourceRoot, options))
			return false;

		if (options.argRunMetadata || options.argDoChecksums
			|| options.argDoFileTypes || options.argDoMediaSig
			|| options.argScanArchives || options.argScanTorrents)
		{
			const bool metadataRequested = options.argDoChecksums
				|| options.argDoFileTypes || options.argDoMediaSig
				|| options.argScanArchives || options.argScanTorrents;
			if ((!options.argScanFiles || !metadataRequested)
				&& !executeRepositoryMetadata(backend, sourceRoot, options))
			{
				return false;
			}
		}

		if (!executeRepositoryExport(backend, sourceRoot, options))
			return false;
		return true;
	}
	catch (Exception ex)
	{
		errorLine("Catalog operation failed: ", ex.msg);
		return false;
	}
}

/** Import a JSON catalog into a repository.
 *
 * Params:
 *     backend = Open catalog backend that receives the import.
 *     repositoryRoot = Repository root used for log output.
 *     options = Parsed command-line options providing the import path and
 *         replace flag.
 * Returns: `true` on success; `false` when the import is cancelled or fails.
 */
bool executeRepositoryImport(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLine("Catalog phase: import JSON.");
	logLineVerbose("Importing into catalog root: ", repositoryRoot);
	JsonImportOptions importOptions;
	importOptions.force = options.argReplaceCatalog;
	auto control = cliOperationControl("Catalog import", repositoryRoot);
	const bool imported = backend.importJsonControlled(
		options.argImportJSON, importOptions, control, 6);
	clearOperationProgress();
	if (!imported)
	{
		errorLine("Catalog import cancelled; the previous catalog was kept.");
		return false;
	}
	logFLine("Imported JSON catalog '%s'.", options.argImportJSON);
	return true;
}

/** Execute a scan or analysis through the shared backend contract.
 *
 * Params:
 *     options = Parsed command-line options; a JSON catalog path selects the
 *         direct JSON operation path and a repository path selects the backend.
 * Returns: The result reported by `reportCatalogOperationResult`; `true` when
 *     the operation completed or a recovery copy was saved.
 */
bool executeCatalogOperation(ArgsArray options)
{
	OperationTarget target;
	if (options.argJSONFile.empty)
	{
		auto repositoryPath = options.argRepositoryPath;
		if (repositoryPath.empty)
			repositoryPath = options.argScanPath;
		if (repositoryPath.empty)
			repositoryPath = ".";
		target = OperationTarget.repositoryTarget(repositoryPath);
	}
	else
	{
		target = OperationTarget.jsonTarget(options.argJSONFile,
			options.argBaseDir);
		return executeJsonCatalogOperation(options, target);
	}

	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(target);
	scope (exit)
		backend.close();
	auto backendTarget = backend.target();
	const auto operationLabel = options.argScanFiles
		? "Catalog scan" : "Catalog analysis";
	const auto operationDetail = options.argJSONFile.empty
		? options.argRepositoryPath.empty ? options.argScanPath
			: options.argRepositoryPath
		: options.argJSONFile;
	auto control = cliOperationControl(operationLabel, operationDetail);
	OperationResult result;
	if (options.argScanFiles)
		result = backend.runOperation(scanRequestFromCli(options, backendTarget),
			control);
	else
		result = backend.runOperation(analysisRequestFromCli(options, backendTarget),
			control);
	clearOperationProgress();
	return reportCatalogOperationResult("Catalog", options, result);
}

/** Run a one-shot JSON operation without the query backend.
 *
 * The operation runner owns the single catalog load and committed replacement.
 * Avoiding the query backend here also avoids rebuilding its read index for a
 * process that exits immediately after the operation.
 *
 * Params:
 *     options = Parsed command-line options selecting scan or analysis.
 *     target = JSON storage target to operate on.
 * Returns: The result reported by `reportCatalogOperationResult`; `true` when
 *     the operation completed or a recovery copy was saved.
 */
private bool executeJsonCatalogOperation(ArgsArray options, OperationTarget target)
{
	const auto operationLabel = options.argScanFiles
		? "Catalog scan" : "Catalog analysis";
	auto control = cliOperationControl(operationLabel, options.argJSONFile);
	OperationResult result;
	if (options.argScanFiles)
		result = runOperation(scanRequestFromCli(options, target), control);
	else
		result = runOperation(analysisRequestFromCli(options, target), control);
	clearOperationProgress();
	return reportCatalogOperationResult("Catalog", options, result);
}

/** Build a scan request from parsed command-line options.
 *
 * Params:
 *     options = Parsed command-line options.
 *     target = Storage target selected by the caller.
 * Returns: The populated request; `operationId` is fixed at 4 for CLI scans.
 */
private ScanOperationRequest scanRequestFromCli(ArgsArray options,
	OperationTarget target)
{
	ScanOperationRequest request;
	request.operationId = 4;
	request.target = target;
	request.scanOptions.recursive = options.argRecursive;
	request.scanOptions.pickHidden = options.argPickHidden;
	request.forceJsonOverwrite = options.argReplaceCatalog;
	request.mergeDuplicates = options.argMergeDuplicates;
	request.savePartialOnCancel = !options.argJSONFile.empty
		&& !options.argDryRun;
	request.dryRun = options.argDryRun;
	request.prettyJson = options.argPrettyJSON;
	request.metadataOptions = metadataOptionsFromCli(options);
	return request;
}

/** Build an analysis request from parsed command-line options.
 *
 * Params:
 *     options = Parsed command-line options.
 *     target = Storage target selected by the caller.
 * Returns: The populated request; `operationId` is fixed at 5 for CLI
 *     analyses.
 */
private AnalysisOperationRequest analysisRequestFromCli(ArgsArray options,
	OperationTarget target)
{
	AnalysisOperationRequest request;
	request.operationId = 5;
	request.target = target;
	request.options.dropMissing = options.argDropMissing;
	request.metadataOptions = metadataOptionsFromCli(options);
	request.forceJsonOverwrite = options.argReplaceCatalog;
	request.dryRun = options.argDryRun;
	request.prettyJson = options.argPrettyJSON;
	return request;
}

/** Whether standard input is attached to a terminal.
 *
 * Returns: `true` on POSIX when `isatty(0)` reports a terminal; always `false`
 *     on other platforms.
 */
private bool stdinIsInteractive()
{
	version (Posix)
	{
		import core.sys.posix.unistd : isatty;
		return isatty(0) != 0;
	}
	else
		return false;
}

/** Copy a recovery catalog to a destination through a temporary staging file.
 *
 * The copy is written to a randomly named sibling of `destination` and renamed
 * into place, so an interrupted copy does not truncate an existing catalog.
 *
 * Params:
 *     source = Existing recovery catalog path.
 *     destination = Final catalog path chosen by the user.
 * Returns: `true` on success; `false` after logging an error and removing the
 *     staging file when the copy fails.
 */
private bool copyRecoveryCatalog(string source, string destination)
{
	import std.file : copy, exists, remove, rename;
	import std.path : dirName;
	import std.uuid : randomUUID;

	const staging = destination ~ ".tmp-" ~ randomUUID().toString();
	try
	{
		copy(source, staging);
		version (Windows)
			if (exists(destination))
				remove(destination);
		rename(staging, destination);
		return true;
	}
	catch (Exception ex)
	{
		if (exists(staging))
		{
			try
				remove(staging);
			catch (Exception)
			{
			}
		}
		errorLine("Could not save the recovery catalog to '%s': %s",
			destination, ex.msg);
		return false;
	}
}

/** Offer to copy a recovery catalog to a user-chosen path.
 *
 * Params:
 *     options = Parsed command-line options providing the default destination
 *         and the no-input flag.
 *     result = Failed operation result carrying the recovery path.
 * Returns: `true` when the user supplied a destination and the copy succeeded;
 *     `false` when there is no recovery file, input is not interactive, the
 *     user cancels, or all copy attempts fail.
 */
private bool offerCatalogRecovery(ArgsArray options, OperationResult result)
{
	import std.file : exists;
	import std.stdio : stdin, stdout;
	import std.string : strip;

	if (result.recoveryPath.empty)
		return false;
	if (!exists(result.recoveryPath))
	{
		errorLine("The reported recovery file '%s' no longer exists.",
			result.recoveryPath);
		return false;
	}
	if (options.argNoInput || !stdinIsInteractive())
	{
		errorLine("Catalog data is available at '%s'.", result.recoveryPath);
		errorLine("Copy it manually or re-run in a terminal without --no-input.");
		return false;
	}

	const defaultTarget = options.argJSONFile;
	foreach (attempt; 0 .. 3)
	{
		stdout.write("Copy recovery catalog to [%s] (empty cancels): ",
			defaultTarget.empty ? "path" : defaultTarget);
		stdout.flush();
		auto destination = strip(stdin.readln());
		if (destination.empty)
		{
			errorLine("Recovery catalog kept at '%s'.", result.recoveryPath);
			return false;
		}
		if (copyRecoveryCatalog(result.recoveryPath, destination))
		{
			noticeFLine("Saved catalog to '%s'.", destination);
			return true;
		}
	}
	return false;
}

/** Log the outcome of a JSON-catalog operation and offer recovery on failure.
 *
 * Params:
 *     backendName = Label used in log messages, for example `"Catalog"`.
 *     options = Parsed command-line options that control the summary detail.
 *     result = Operation result to report.
 * Returns: `true` when the operation completed, or when a failed operation's
 *     recovery catalog was successfully copied; `false` otherwise.
 */
private bool reportCatalogOperationResult(string backendName, ArgsArray options,
	OperationResult result)
{
	const bool cancelledWithSavedData = result.state == OperationState.cancelled
		&& result.changesCommitted;
	if (result.state != OperationState.completed && !cancelledWithSavedData)
	{
		if (result.state == OperationState.cancelled)
			errorLine(backendName ~ " operation cancelled; no changes were written.");
		else
		{
			errorLine(backendName ~ " operation failed: ", result.error);
			if (offerCatalogRecovery(options, result))
				return true;
		}
		return false;
	}
	if (cancelledWithSavedData)
		errorLine(backendName ~ " operation cancelled; collected data was saved.");
	if (result.operation == OperationKind.scan)
	{
		logFLine("%s scan: %d files, %d added, %d changed.", backendName,
			result.scanSummary.filesFound, result.scanSummary.filesAdded,
			result.scanSummary.filesChanged);
		logFLine("%s metadata: %d blobs, %d checksum, %d file type, "
			~ "%d media, %d archive, %d torrent updates, %d failures.",
			backendName, result.metadataSummary.blobsVisited,
			result.metadataSummary.checksumsUpdated,
			result.metadataSummary.fileTypesUpdated,
			result.metadataSummary.mediaInfoUpdated,
			result.metadataSummary.archivesUpdated,
			result.metadataSummary.torrentsUpdated,
			result.metadataSummary.failed);
		if (options.argMergeDuplicates)
			logFLine("%s duplicate analysis: %d groups, %d merged blobs.",
				backendName, result.analysisSummary.duplicateGroups,
				result.analysisSummary.mergedBlobs);
	}
	else
	{
		const bool ranMetadata = options.argDoChecksums
			|| options.argDoFileTypes || options.argDoMediaSig
			|| options.argScanArchives != 0 || options.argScanTorrents;
		if (ranMetadata)
			logFLine("%s metadata: %d blobs, %d checksum, %d file type, "
				~ "%d media, %d archive, %d torrent updates, %d failures.",
				backendName, result.metadataSummary.blobsVisited,
				result.metadataSummary.checksumsUpdated,
				result.metadataSummary.fileTypesUpdated,
				result.metadataSummary.mediaInfoUpdated,
				result.metadataSummary.archivesUpdated,
				result.metadataSummary.torrentsUpdated,
				result.metadataSummary.failed);
		logFLine("%s analysis: %d missing, %d dropped, %d duplicate groups, "
			~ "%d merged blobs, %d orphaned blobs.", backendName,
			result.analysisSummary.missingFiles,
			result.analysisSummary.droppedFiles,
			result.analysisSummary.duplicateGroups,
			result.analysisSummary.mergedBlobs,
			result.analysisSummary.orphanedBlobs);
	}
	if (options.argDryRun)
		logLine("Dry run: " ~ backendName ~ " catalog was not written.");
	else if (result.state == OperationState.completed)
		logLine(backendName ~ " operation complete.");
	return result.state == OperationState.completed;
}

/** Export the repository catalog when requested.
 *
 * Params:
 *     backend = Open catalog backend to export from.
 *     repositoryRoot = Repository root used for log output.
 *     options = Parsed command-line options providing the export path, subset
 *         prefix and JSON formatting.
 * Returns: `true` when no export was requested or the export was committed;
 *     `false` when the prefix matches nothing or the export is cancelled.
 */
bool executeRepositoryExport(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	auto exportPath = options.argExportJSON;
	if (exportPath.empty && options.argWriteJSON)
		exportPath = options.argJSONFile;
	if (exportPath.empty)
		return true;
	logLine("Catalog phase: export JSON.");
	logLineVerbose("Exporting catalog root: ", repositoryRoot);
	if (!options.argExportPath.empty)
	{
		logLineVerbose("Export path prefix: ", options.argExportPath);
		if (!catalogHasPath(backend, options.argExportPath))
		{
			errorFLine("No catalog references match path '%s'.",
				options.argExportPath);
			return false;
		}
	}
	CatalogExportOptions exportOptions;
	exportOptions.outputPath = exportPath;
	exportOptions.format = CatalogExportFormat.jsonV5;
	exportOptions.prettyJson = options.argPrettyJSON;
	auto control = cliOperationControl("Catalog export", exportPath);
	CatalogSubsetQuery subset;
	subset.pathPrefix = options.argExportPath;
	subset.filter.includeArchiveMembers = true;
	auto result = backend.exportSubsetControlled(
		subset, exportOptions, control, 7);
	clearOperationProgress();
	if (!result.committed)
	{
		errorLine("Catalog export cancelled; no catalog was written.");
		return false;
	}
	logFLine("Exported repository JSON to '%s'.", result.outputPath);
	return true;
}

/** Print catalog metadata and current content counts.
 *
 * Params:
 *     backend = Open catalog backend to query.
 *     repositoryRoot = Repository root used to derive the database path.
 *     options = Parsed command-line options selecting table or JSON output.
 */
void executeRepositoryInfo(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	auto info = backend.repositoryInfo();
	RepositoryQueryOptions query;
	query.limit = 1;
	auto page = backend.queryBlobs(query);
	CatalogFilter filter;
	filter.includeArchiveMembers = true;
	const references = backend.rootSummary(filter).fileReferenceCount;
	if (options.argOutputFormat == "json")
	{
		logFLine("{\"root\":%s,\"database\":%s,\"schemaVersion\":%d,"
			~ "\"createdAt\":%s,\"updatedAt\":%s,\"blobs\":%d,"
			~ "\"references\":%d}",
			jsonQuote(info.rootPath),
			jsonQuote(buildPath(repositoryRoot, repositoryDirectoryName,
				repositoryDatabaseFileName)),
			info.schemaVersion, jsonQuote(info.createdAt), jsonQuote(info.updatedAt),
			page.total, references);
		return;
	}
	logFLine("Catalog root: %s", info.rootPath);
	logFLine("Database: %s", buildPath(repositoryRoot, repositoryDirectoryName,
		repositoryDatabaseFileName));
	logFLine("Schema version: %d", info.schemaVersion);
	logFLine("Created: %s", info.createdAt);
	logFLine("Updated: %s", info.updatedAt);
	logFLine("Blobs: %d", page.total);
	logFLine("References: %d", references);
}

/** Build the shared catalog filter from query command-line options.
 *
 * Params:
 *     options = Parsed command-line options carrying text and media filters.
 * Returns: A filter with all supplied criteria set and archive members
 *     included.
 */
private CatalogFilter catalogFilterFromCli(ArgsArray options)
{
	CatalogFilter filter;
	filter.pathText = options.argQueryText;
	filter.video = options.argQueryVideo;
	filter.audio = options.argQueryAudio;
	filter.image = options.argQueryImage;
	filter.text = options.argQueryTextStream;
	filter.fileType = options.argQueryFileType;
	filter.archive = options.argQueryArchive;
	filter.torrent = options.argQueryTorrent;
	filter.includeArchiveMembers = true;
	return filter;
}

/** Collect all matching file references, including indexed archive members.
 *
 * Params:
 *     backend = Open catalog backend to walk.
 *     filter = Filter applied to directory and file queries.
 * Returns: All matching files sorted by relative path; empty when nothing
 *     matches.
 */
private CatalogFile[] collectCatalogFiles(CatalogBackend backend,
	CatalogFilter filter)
{
	import std.algorithm.sorting : sort;

	CatalogFile[] files;

	void collectDirectory(DirectoryId parentId)
	{
		CatalogDirectoryQuery directoryQuery;
		directoryQuery.parentId = parentId;
		directoryQuery.filter = filter;
		CatalogPageRequest directoryPageRequest;
		while (true)
		{
			auto page = backend.listDirectories(directoryQuery, directoryPageRequest);
			foreach (directory; page.directories)
				collectDirectory(directory.id);
			if (!page.hasMore)
				break;
			directoryPageRequest.cursor = page.nextCursor;
		}

		CatalogFileQuery fileQuery;
		fileQuery.directoryId = parentId;
		fileQuery.filter = filter;
		fileQuery.sortOrder = CatalogSortOrder.pathAscending;
		CatalogPageRequest filePageRequest;
		while (true)
		{
			auto page = backend.listFiles(fileQuery, filePageRequest);
			files ~= page.files;
			if (!page.hasMore)
				break;
			filePageRequest.cursor = page.nextCursor;
		}
	}

	collectDirectory(DirectoryId.init);
	files.sort!((left, right) => left.relativePath < right.relativePath);
	return files;
}

/** Report whether one canonical path or descendant prefix has references.
 *
 * Params:
 *     backend = Open catalog backend to search.
 *     prefix = Canonical path or virtual archive path prefix.
 * Returns: `true` when an exact reference or any descendant matches.
 */
private bool catalogHasPath(CatalogBackend backend, string prefix)
{
	CatalogFilter filter;
	filter.pathText = prefix;
	filter.caseSensitive = true;
	filter.includeArchiveMembers = true;

	static bool isMatch(string path, string prefix)
	{
		return path == prefix || path.startsWith(prefix ~ "/")
			|| path.startsWith(prefix ~ archivePathSeparator());
	}

	/* Walk only directories that are ancestors of the prefix or below it and
	 * stop at the first matching file instead of materializing the catalog. */
	bool walk(DirectoryId parentId)
	{
		CatalogFileQuery fileQuery;
		fileQuery.directoryId = parentId;
		fileQuery.filter = filter;
		CatalogPageRequest fileRequest;
		while (true)
		{
			auto page = backend.listFiles(fileQuery, fileRequest);
			foreach (file; page.files)
				if (isMatch(file.relativePath, prefix))
					return true;
			if (!page.hasMore)
				break;
			fileRequest.cursor = page.nextCursor;
		}

		CatalogDirectoryQuery directoryQuery;
		directoryQuery.parentId = parentId;
		CatalogPageRequest directoryRequest;
		while (true)
		{
			auto page = backend.listDirectories(directoryQuery, directoryRequest);
			foreach (directory; page.directories)
			{
				const path = directory.relativePath;
				const bool ancestor = prefix == path
					|| prefix.startsWith(path ~ "/");
				const bool descendant = path.startsWith(prefix ~ "/");
				if ((ancestor || descendant) && walk(directory.id))
					return true;
			}
			if (!page.hasMore)
				break;
			directoryRequest.cursor = page.nextCursor;
		}
		return false;
	}

	return walk(DirectoryId.init);
}

/** Original member name without the canonical occurrence suffix.
 *
 * Params:
 *     path = Canonical path, with or without archive layers.
 * Returns: The final name of the deepest layer, or the raw path's base name
 *     when the path does not follow the canonical grammar.
 */
private string displayNameForPath(string path)
{
	try
	{
		const auto parsed = parseArchiveVirtualPath(path);
		if (parsed.entries.length > 0)
			return baseName(parsed.entries[$ - 1].relativePath);
		return baseName(parsed.physicalPath);
	}
	catch (Exception)
		return baseName(path);
}

/** Print a blob page for JSON catalogs without a bound filesystem root.
 *
 * Params:
 *     backend = Open catalog backend to query.
 *     options = Parsed command-line options providing filters, paging and
 *         output format.
 */
private void executeRepositoryListLegacy(CatalogBackend backend,
	ArgsArray options)
{
	RepositoryQueryOptions query;
	query.offset = options.argQueryOffset;
	query.limit = options.argQueryLimit;
	query.text = options.argQueryText;
	query.video = options.argQueryVideo;
	query.audio = options.argQueryAudio;
	query.image = options.argQueryImage;
	query.textStream = options.argQueryTextStream;
	query.fileType = options.argQueryFileType;
	query.archive = options.argQueryArchive;
	query.torrent = options.argQueryTorrent;

	auto page = backend.queryBlobs(query);
	if (options.argOutputFormat == "json")
	{
		string output = format("{\"total\":%d,\"offset\":%d,\"items\":[",
			page.total, query.offset);
		foreach (index, blob; page.blobs)
		{
			if (index > 0)
				output ~= ",";
			const path = blob.getFirstFileName();
			output ~= format("{\"id\":%d,\"size\":%d,\"name\":%s,\"path\":%s}",
				page.blobIds[index], blob.fileSize,
				jsonQuote(displayNameForPath(path)), jsonQuote(path));
		}
		logLine(output ~ "]}");
		return;
	}
	logFLine("Showing %d of %d matching blobs (offset %d).", page.blobs.length,
		page.total, query.offset);
	logLine("ID\tSize\tName\tPath");
	foreach (index, blob; page.blobs)
	{
		const path = blob.getFirstFileName();
		logFLine("%d\t%d\t%s\t%s", page.blobIds[index], blob.fileSize,
			displayNameForPath(path), path);
	}
}

/** Print one bounded, catalog-side filtered page of file references.
 *
 * Params:
 *     backend = Open catalog backend to query.
 *     repositoryRoot = Repository root used for verbose log output.
 *     options = Parsed command-line options providing filters, paging and
 *         output format.
 */
void executeRepositoryList(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLineVerbose("Listing catalog root: ", repositoryRoot);
	if (!backend.capabilities().supportsTreeQueries)
	{
		executeRepositoryListLegacy(backend, options);
		return;
	}
	const auto filter = catalogFilterFromCli(options);
	const auto files = collectCatalogFiles(backend, filter);
	const auto total = files.length;
	const auto start = options.argQueryOffset < total
		? options.argQueryOffset : total;
	const auto remaining = total - start;
	const auto count = options.argQueryLimit < remaining
		? options.argQueryLimit : remaining;
	const auto visible = files[start .. start + count];

	if (options.argOutputFormat == "json")
	{
		string output = format("{\"total\":%d,\"offset\":%d,\"items\":[",
			total, options.argQueryOffset);
		foreach (index, file; visible)
		{
			if (index > 0)
				output ~= ",";
			output ~= format("{\"id\":%d,\"size\":%d,\"name\":%s,\"path\":%s}",
				file.referenceId.toHash, file.size,
				jsonQuote(file.name), jsonQuote(file.relativePath));
		}
		logLine(output ~ "]}");
		return;
	}
	logFLine("Showing %d of %d matching references (offset %d).", visible.length,
		total, options.argQueryOffset);
	logLine("ID\tSize\tName\tPath");
	foreach (file; visible)
		logFLine("%d\t%d\t%s\t%s", file.referenceId.toHash, file.size,
			file.name, file.relativePath);
}

/** Print duplicate groups for JSON catalogs without a bound root.
 *
 * Params:
 *     backend = Open catalog backend to query.
 *     options = Parsed command-line options providing the duplicate limit and
 *         output format.
 */
private void executeRepositoryDuplicatesLegacy(CatalogBackend backend,
	ArgsArray options)
{
	auto groups = backend.queryDuplicateGroups(options.argDuplicateLimit);
	long[] neededIds;
	bool[long] seenId;
	foreach (group; groups)
		foreach (blobId; group.blobIds)
			if (blobId !in seenId)
			{
				seenId[blobId] = true;
				neededIds ~= blobId;
			}
	RepositoryQueryOptions lookupQuery;
	lookupQuery.blobIds = neededIds;
	lookupQuery.limit = neededIds.length > 0 ? neededIds.length : 1;
	auto blobs = backend.queryBlobs(lookupQuery);
	string[long] pathByBlobId;
	foreach (index, blob; blobs.blobs)
		pathByBlobId[blobs.blobIds[index]] = blob.getFirstFileName();
	if (options.argOutputFormat == "json")
	{
		string output = "{\"groups\":[";
		foreach (groupIndex, group; groups)
		{
			if (groupIndex > 0)
				output ~= ",";
			output ~= format("{\"size\":%d,\"blobs\":[", group.fileSize);
			foreach (blobIndex, blobId; group.blobIds)
			{
				if (blobIndex > 0)
					output ~= ",";
				const path = pathByBlobId.get(blobId, "");
				output ~= format("{\"id\":%d,\"name\":%s,\"path\":%s}",
					blobId, jsonQuote(displayNameForPath(path)),
					jsonQuote(path));
			}
			output ~= "]}";
		}
		logLine(output ~ "]}");
		return;
	}
	logFLine("Found %d duplicate groups.", groups.length);
	foreach (groupIndex, group; groups)
	{
		logFLine("Group %d: %d bytes, %d blobs", groupIndex + 1,
			group.fileSize, group.blobIds.length);
		foreach (blobId; group.blobIds)
		{
			const path = pathByBlobId.get(blobId, "");
			logFLine("  %d\t%s\t%s", blobId, displayNameForPath(path), path);
		}
	}
}

/** Print duplicate groups without modifying catalog contents.
 *
 * Params:
 *     backend = Open catalog backend to query.
 *     repositoryRoot = Repository root used for verbose log output.
 *     options = Parsed command-line options providing the duplicate limit and
 *         output format.
 * Throws: `CatalogBackendException` when the duplicate limit is zero.
 */
void executeRepositoryDuplicates(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	import std.algorithm.sorting : sort;
	import std.array : appender;

	logLineVerbose("Querying duplicate groups in catalog root: ", repositoryRoot);
	if (options.argDuplicateLimit == 0)
		throw new CatalogBackendException(
			CatalogBackendErrorCode.invalidIdentifier,
			"Duplicate query limit must be greater than zero.");
	if (!backend.capabilities().supportsTreeQueries)
	{
		executeRepositoryDuplicatesLegacy(backend, options);
		return;
	}
	CatalogFilter filter;
	filter.includeArchiveMembers = true;
	const auto files = collectCatalogFiles(backend, filter);

	struct Group
	{
		ulong size;
		CatalogFile[] references;
	}

	CatalogFile[][ContentId] byContent;
	foreach (file; files)
		byContent[file.contentId] ~= file;

	auto groups = appender!(Group[])();
	foreach (contentId, references; byContent)
		if (references.length > 1)
			groups.put(Group(references[0].size, references));
	auto result = groups.data;
	result.sort!((left, right) => left.size != right.size
		? left.size < right.size
		: left.references[0].relativePath < right.references[0].relativePath);
	const auto groupCount = options.argDuplicateLimit < result.length
		? options.argDuplicateLimit : result.length;
	const auto visible = result[0 .. groupCount];

	if (options.argOutputFormat == "json")
	{
		string output = "{\"groups\":[";
		foreach (groupIndex, group; visible)
		{
			if (groupIndex > 0)
				output ~= ",";
			output ~= format("{\"size\":%d,\"blobs\":[", group.size);
			foreach (referenceIndex, file; group.references)
			{
				if (referenceIndex > 0)
					output ~= ",";
				output ~= format("{\"id\":%d,\"name\":%s,\"path\":%s}",
					file.referenceId.toHash, jsonQuote(file.name),
					jsonQuote(file.relativePath));
			}
			output ~= "]}";
		}
		logLine(output ~ "]}");
		return;
	}
	logFLine("Found %d duplicate groups.", visible.length);
	foreach (groupIndex, group; visible)
	{
		logFLine("Group %d: %d bytes, %d references", groupIndex + 1,
			group.size, group.references.length);
		foreach (file; group.references)
			logFLine("  %d\t%s\t%s", file.referenceId.toHash, file.name,
				file.relativePath);
	}
}

/** Quote a string for the small, stable CLI JSON result objects.
 *
 * Params:
 *     value = Raw string to encode.
 * Returns: The string enclosed in double quotes with control characters and
 *     quotes escaped.
 */
string jsonQuote(string value)
{
	import std.format : format;

	string result = "\"";
	foreach (c; value)
	{
		switch (c)
		{
		case '"':
			result ~= "\\\"";
			break;
		case '\\':
			result ~= "\\\\";
			break;
		case '\n':
			result ~= "\\n";
			break;
		case '\r':
			result ~= "\\r";
			break;
		case '\t':
			result ~= "\\t";
			break;
		default:
			if (c < 0x20)
				result ~= format("\\u%04x", cast(uint) c);
			else
				result ~= c;
			break;
		}
	}
	return result ~ "\"";
}

/** Execute the selected metadata extractors against a repository.
 *
 * Params:
 *     backend = Open catalog backend that runs the metadata operation.
 *     repositoryRoot = Repository root used as the operation target and log
 *         label.
 *     options = Parsed command-line options selecting extractors and thread
 *         count.
 * Returns: `true` when the operation completed; `false` after logging the
 *     cancellation or failure.
 */
bool executeRepositoryMetadata(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	MetadataScanOptions metadataOptions;
	metadataOptions.calculateChecksums = options.argDoChecksums;
	metadataOptions.detectFileTypes = options.argDoFileTypes;
	metadataOptions.extractMediaInfo = options.argDoMediaSig;
	metadataOptions.scanArchives = options.argScanArchives != 0;
	metadataOptions.deepArchiveScan = options.argScanArchives > 1;
	metadataOptions.scanTorrents = options.argScanTorrents;
	metadataOptions.rescan = options.argRescanMediaSig;
	metadataOptions.threads = options.argNumberOfThreads > 1
		? cast(size_t) options.argNumberOfThreads : 1;
	MetadataOperationRequest request;
	request.operationId = 2;
	request.target = OperationTarget.repositoryTarget(repositoryRoot);
	request.options = metadataOptions;
	auto control = cliOperationControl("Catalog metadata", repositoryRoot);
	auto result = backend.runOperation(request, control);
	clearOperationProgress();
	if (result.state != OperationState.completed)
	{
		if (result.state == OperationState.cancelled)
            errorLine("Catalog metadata operation cancelled.");
		else
			errorLine("Catalog metadata operation failed: ", result.error);
		return false;
	}
	auto summary = result.metadataSummary;
	logFLine("Metadata update: %d blobs, %d checksum, %d file type, "
		~ "%d media, %d archive, %d torrent updates, %d failures.",
		summary.blobsVisited, summary.checksumsUpdated,
		summary.fileTypesUpdated, summary.mediaInfoUpdated,
		summary.archivesUpdated, summary.torrentsUpdated, summary.failed);
	return true;
}

/** Render shared operation progress and translate SIGINT into cooperative cancellation.
 *
 * Params:
 *     label = Operation label shown in progress output.
 *     detail = Optional detail such as the target path.
 * Returns: A control object whose progress callback writes to the CLI.
 */
OperationControl cliOperationControl(string label, string detail = "")
{
	prepareOperationOutput(label, detail);
	OperationControl control;
	SysTime lastVerboseProgress;
	bool haveVerboseProgress;
	size_t lastReported;
	ulong lastSubtaskReported;
	string lastReportedPath;
	control = new OperationControl((OperationProgress event) {
		// Signal handlers only set a flag; mutex/condition work happens here.
		if (atomicLoad(gotCtrlC) && !control.cancellationRequested)
			control.requestCancellation();
		if (isVerboseOutputs())
		{
			if (event.state == OperationState.running)
				printVerboseOperationProgress(label, event,
					lastVerboseProgress, haveVerboseProgress);
		}
		else if (event.state == OperationState.running)
			printOperationProgress(label, event);
	});
	return control;
}

/** A handler for OS signals
 *
 * Checksumming files can take some time. The handler allows to catch
 * a Control-C event and signal threads to exit.
 * Data can then be written to disk instead of immediately breaking the
 * program.
 *
 * Params:
 *   sig = signal number to process
 */
extern (C) nothrow @nogc @system void signalHandler(int sig)
{
	import core.stdc.stdlib : abort;
	import core.sys.posix.unistd : STDERR_FILENO, _exit, write;

	bool do_abort = false;
	debug (all)
	{
		enum message = "Got signal\n";
		write(STDERR_FILENO, message.ptr, message.length);
	}
	switch (sig)
	{
	case SIGINT:
		if (atomicLoad(gotCtrlC))
		{
			enum hardStop = "Second Ctrl-C received. Terminating immediately.\n";
			write(STDERR_FILENO, hardStop.ptr, hardStop.length);
			_exit(1);
		}
		else
		{
			enum waitMessage = "Ctrl-C received. Waiting for the application to finish before exiting. Press Ctrl-C again to terminate immediately.\n";
			write(STDERR_FILENO, waitMessage.ptr, waitMessage.length);
			atomicStore(gotCtrlC, true);
		}
		break;
	case SIGTERM:
		do_abort = true;
		break;
	default:
		break;
	}
	if (do_abort)
		abort();
}

/** Map shared scanner CLI flags to frontend-neutral library options.
 *
 * Params:
 *     options = Parsed command-line options.
 * Returns: Metadata options mirroring the enabled scanner flags.
 */
MetadataScanOptions metadataOptionsFromCli(ArgsArray options)
{
	MetadataScanOptions metadata;
	metadata.calculateChecksums = options.argDoChecksums;
	metadata.detectFileTypes = options.argDoFileTypes;
	metadata.extractMediaInfo = options.argDoMediaSig;
	metadata.scanArchives = options.argScanArchives != 0;
	metadata.deepArchiveScan = options.argScanArchives > 1;
	metadata.scanTorrents = options.argScanTorrents;
	metadata.rescan = options.argRescanMediaSig;
	metadata.threads = options.argNumberOfThreads > 1
		? cast(size_t) options.argNumberOfThreads : 1;
	return metadata;
}
