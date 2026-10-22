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
import dosierskanilo_cli.logging : errorLine;

version (ldc)
{
	import ldc.eh_msvc;
}

/* ----------------------------------------------------------------------- */

/* The global wrapper with all file objects and shared metadata */
/* Custom CTRL-C handler for a smooth abort of running scan operation */
shared bool gotCtrlC; /// Set in handler

/* Some constants */
immutable string appName = "DosierSkanilo";
immutable string appVersion = import("build/bin/build-version.txt").strip;

/** Main Entry
 *
 * Decode command-line parameters and run the scanner workflow.
 * When unit testing, do nothing.
 *
 * Params:
 *   args = command-line arguments
 * Returns:
 *   shell return code
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
			if (options.argDoMediaSig)
			{
				auto miv = getMediaInfoVersion();
				logLineVerbose("Using ", miv);
			}
			const auto oldhandler = signal(SIGINT, &signalHandler);
			if (oldhandler == SIG_ERR)
				logLine("Warning: could not install the SIGINT handler.");
			scope (exit)
				if (oldhandler != SIG_ERR)
					signal(SIGINT, oldhandler);

			bool rc;
			if (parsed.command == CliCommand.scan || parsed.command == CliCommand.analyze)
				rc = executeCatalogOperation(options);
			else
				rc = executeRepositoryOperation(options);
			return rc ? 0 : 1;
		}
	}
}

/** Execute a SQLite repository operation selected by the CLI options. */
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
				repository = Repository.initialize(repositoryPath);
				if (databaseAlreadyExists)
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

		if (!options.argImportJSON.empty)
			executeRepositoryImport(backend, sourceRoot, options);

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

		executeRepositoryExport(backend, sourceRoot, options);
		return true;
	}
	catch (Exception ex)
	{
		errorLine("Catalog operation failed: ", ex.msg);
		return false;
	}
}

/** Import a JSON catalog into a repository. */
void executeRepositoryImport(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLine("Catalog phase: import JSON.");
	logLineVerbose("Importing into catalog root: ", repositoryRoot);
	JsonImportOptions importOptions;
	importOptions.force = options.argReplaceCatalog;
	backend.importJson(options.argImportJSON, importOptions);
	logFLine("Imported JSON catalog '%s'.", options.argImportJSON);
}

/** Execute a scan or analysis through the shared backend contract. */
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
		target = OperationTarget.jsonTarget(options.argJSONFile, options.argBaseDir);

	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(target);
	scope (exit)
		backend.close();
	auto backendTarget = backend.target();
	auto backendName = "Catalog";
	auto control = cliOperationControl(options.argScanFiles
		? "Catalog scan" : "Catalog analysis");
	OperationResult result;
	if (options.argScanFiles)
	{
		ScanOperationRequest request;
		request.operationId = 4;
		request.target = backendTarget;
		request.scanOptions.recursive = options.argRecursive;
		request.scanOptions.pickHidden = options.argPickHidden;
		request.forceJsonOverwrite = options.argReplaceCatalog;
		request.mergeDuplicates = options.argMergeDuplicates;
		request.dryRun = options.argDryRun;
		request.metadataOptions = metadataOptionsFromCli(options);
		result = backend.runOperation(request, control);
		clearOperationProgress();
	}
	else
	{
		AnalysisOperationRequest request;
		request.operationId = 5;
		request.target = backendTarget;
		request.options.dropMissing = options.argDropMissing;
		request.metadataOptions = metadataOptionsFromCli(options);
		request.forceJsonOverwrite = options.argReplaceCatalog;
		request.dryRun = options.argDryRun;
		result = backend.runOperation(request, control);
		clearOperationProgress();
	}

	if (result.state != OperationState.completed)
	{
		if (result.state == OperationState.cancelled)
			errorLine(backendName ~ " operation cancelled; the original catalog was not replaced.");
		else
			errorLine(backendName ~ " operation failed: ", result.error);
		return false;
	}
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
	logLine(backendName ~ " operation complete.");
	return true;
}

/** Export the repository catalog when requested. */
void executeRepositoryExport(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	auto exportPath = options.argExportJSON;
	if (exportPath.empty && options.argWriteJSON)
		exportPath = options.argJSONFile;
	if (exportPath.empty)
		return;
	logLine("Catalog phase: export JSON.");
	logLineVerbose("Exporting catalog root: ", repositoryRoot);
	CatalogExportOptions exportOptions;
	exportOptions.outputPath = exportPath;
	exportOptions.format = CatalogExportFormat.jsonV5;
	auto result = backend.exportSubset(CatalogSubsetQuery("", CatalogFilter.init),
		exportOptions);
	logFLine("Exported repository JSON to '%s'.", result.outputPath);
}

/** Print catalog metadata and current content counts. */
void executeRepositoryInfo(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	auto info = backend.repositoryInfo();
	RepositoryQueryOptions query;
	query.limit = 1;
	auto page = backend.queryBlobs(query);
	if (options.argOutputFormat == "json")
	{
		logFLine("{\"root\":%s,\"database\":%s,\"schemaVersion\":%d,"
			~ "\"createdAt\":%s,\"updatedAt\":%s,\"blobs\":%d}",
			jsonQuote(info.rootPath),
			jsonQuote(buildPath(repositoryRoot, repositoryDirectoryName,
				repositoryDatabaseFileName)),
			info.schemaVersion, jsonQuote(info.createdAt), jsonQuote(info.updatedAt),
			page.total);
		return;
	}
	logFLine("Catalog root: %s", info.rootPath);
	logFLine("Database: %s", buildPath(repositoryRoot, repositoryDirectoryName,
		repositoryDatabaseFileName));
	logFLine("Schema version: %d", info.schemaVersion);
	logFLine("Created: %s", info.createdAt);
	logFLine("Updated: %s", info.updatedAt);
	logFLine("Blobs: %d", page.total);
}

/** Print one bounded, catalog-side filtered page of blobs. */
void executeRepositoryList(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLineVerbose("Listing catalog root: ", repositoryRoot);
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
			output ~= format("{\"id\":%d,\"size\":%d,\"path\":%s}",
				page.blobIds[index], blob.fileSize,
				jsonQuote(blob.getFirstFileName()));
		}
		logLine(output ~ "]}");
		return;
	}
	logFLine("Showing %d of %d matching blobs (offset %d).", page.blobs.length,
		page.total, query.offset);
	logLine("ID\tSize\tPath");
	foreach (index, blob; page.blobs)
		logFLine("%d\t%d\t%s", page.blobIds[index], blob.fileSize,
			blob.getFirstFileName());
}

/** Print duplicate groups without modifying catalog contents. */
void executeRepositoryDuplicates(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLineVerbose("Querying duplicate groups in catalog root: ", repositoryRoot);
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
				output ~= format("{\"id\":%d,\"path\":%s}", blobId,
					jsonQuote(pathByBlobId.get(blobId, "")));
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
			logFLine("  %d\t%s", blobId, pathByBlobId.get(blobId, ""));
		}
	}
}

/** Quote a string for the small, stable CLI JSON result objects. */
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

/** Execute the selected metadata extractors against a repository. */
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
	auto control = cliOperationControl("Catalog metadata");
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

/** Render shared operation progress and translate SIGINT into cooperative cancellation. */
OperationControl cliOperationControl(string label)
{
	OperationControl control;
	OperationPhase lastPhase = OperationPhase.none;
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
			{
				if (event.phase != lastPhase)
				{
					lastPhase = event.phase;
					logFLineVerbose("%s phase: %s.", label, event.phase);
				}
			}
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
			_exit(1);
		else
			atomicStore(gotCtrlC, true);
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

/** Map shared scanner CLI flags to frontend-neutral library options. */
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
