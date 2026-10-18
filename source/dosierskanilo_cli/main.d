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
			auto oldhandler = signal(SIGINT, &signalHandler);
			assert(oldhandler != SIG_ERR, "Problem setting signal handler");
			scope (exit)
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
	try
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
		if (options.argShowInfo)
		{
			executeRepositoryInfo(repository, options);
			repository.close();
			return true;
		}
		if (options.argList)
		{
			executeRepositoryList(repository, options);
			repository.close();
			return true;
		}
		if (options.argDuplicates)
		{
			executeRepositoryDuplicates(repository, options);
			repository.close();
			return true;
		}

		if (!options.argImportJSON.empty)
			executeRepositoryImport(repository, options);

		if (options.argRunMetadata || options.argDoChecksums
			|| options.argDoFileTypes || options.argDoMediaSig
			|| options.argScanArchives || options.argScanTorrents)
		{
			const bool metadataRequested = options.argDoChecksums
				|| options.argDoFileTypes || options.argDoMediaSig
				|| options.argScanArchives || options.argScanTorrents;
			if ((!options.argScanFiles || !metadataRequested)
				&& !executeRepositoryMetadata(repository, options))
			{
				repository.close();
				return false;
			}
		}

		executeRepositoryExport(repository, options);
		repository.close();
		return true;
	}
	catch (Exception ex)
	{
		if (repository !is null)
			repository.close();
		errorLine("Repository operation failed: ", ex.msg);
		return false;
	}
}

/** Import a JSON catalog into a repository. */
void executeRepositoryImport(Repository repository, ArgsArray options)
{
	logLine("Repository phase: import JSON.");
	repository.appendLog("json.import", options.argImportJSON);
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
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
	auto backendName = backendTarget.mode == OperationStorageMode.jsonCatalog
		? "JSON" : "Repository";
	auto control = cliOperationControl(backendName ~ (options.argScanFiles
		? " scan" : " analysis"));
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
		if (backendName == "Repository")
			logFLine("%s analysis: %d missing, %d dropped, %d duplicate groups, "
				~ "%d merged blobs, %d orphaned blobs.", backendName,
				result.analysisSummary.missingFiles,
				result.analysisSummary.droppedFiles,
				result.analysisSummary.duplicateGroups,
				result.analysisSummary.mergedBlobs,
				result.analysisSummary.orphanedBlobs);
		else
			logFLine("%s analysis: %d missing, %d dropped, %d duplicate groups, "
				~ "%d merged blobs.", backendName,
				result.analysisSummary.missingFiles,
				result.analysisSummary.droppedFiles,
				result.analysisSummary.duplicateGroups,
				result.analysisSummary.mergedBlobs);
	}
	if (options.argDryRun)
		logLine("Dry run: " ~ backendName ~ " catalog was not written.");
	logLine(backendName ~ " operation complete.");
	return true;
}

/** Export the repository catalog when requested. */
void executeRepositoryExport(Repository repository, ArgsArray options)
{
	auto exportPath = options.argExportJSON;
	if (exportPath.empty && options.argWriteJSON)
		exportPath = options.argJSONFile;
	if (exportPath.empty)
		return;
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
	logLine("Repository phase: export JSON.");
	repository.appendLog("json.export", exportPath);
	CatalogExportOptions exportOptions;
	exportOptions.outputPath = exportPath;
	exportOptions.format = CatalogExportFormat.jsonV5;
	auto result = backend.exportSubset(CatalogSubsetQuery("", CatalogFilter.init),
		exportOptions);
	logFLine("Exported repository JSON to '%s'.", result.outputPath);
}

/** Print repository metadata and current catalog counts. */
void executeRepositoryInfo(Repository repository, ArgsArray options)
{
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
	auto info = backend.repositoryInfo();
	RepositoryQueryOptions query;
	query.limit = 1;
	auto page = backend.queryBlobs(query);
	if (options.argOutputFormat == "json")
	{
		logFLine("{\"root\":%s,\"database\":%s,\"schemaVersion\":%d,"
			~ "\"createdAt\":%s,\"updatedAt\":%s,\"blobs\":%d}",
			jsonQuote(info.rootPath),
			jsonQuote(buildPath(info.rootPath, repositoryDirectoryName,
				repositoryDatabaseFileName)),
			info.schemaVersion, jsonQuote(info.createdAt), jsonQuote(info.updatedAt),
			page.total);
		return;
	}
	logFLine("Repository root: %s", info.rootPath);
	logFLine("Database: %s", buildPath(info.rootPath, repositoryDirectoryName,
		repositoryDatabaseFileName));
	logFLine("Schema version: %d", info.schemaVersion);
	logFLine("Created: %s", info.createdAt);
	logFLine("Updated: %s", info.updatedAt);
	logFLine("Blobs: %d", page.total);
}

/** Print one bounded, repository-side filtered page of blobs. */
void executeRepositoryList(Repository repository, ArgsArray options)
{
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
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

/** Print duplicate groups without modifying repository contents. */
void executeRepositoryDuplicates(Repository repository, ArgsArray options)
{
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
	auto groups = backend.queryDuplicateGroups(options.argDuplicateLimit);
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
				auto blob = repository.loadBlobDetails(blobId);
				output ~= format("{\"id\":%d,\"path\":%s}", blobId,
					jsonQuote(blob.getFirstFileName()));
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
			auto blob = repository.loadBlobDetails(blobId);
			logFLine("  %d\t%s", blobId,
				blob.getFirstFileName());
		}
	}
}

/** Quote a string for the small, stable CLI JSON result objects. */
string jsonQuote(string value)
{
	return "\"" ~ value.replace("\\", "\\\\").replace("\"", "\\\"")
		.replace("\n", "\\n").replace("\r", "\\r") ~ "\"";
}

/** Execute the selected metadata extractors against a repository. */
bool executeRepositoryMetadata(Repository repository, ArgsArray options)
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
	request.target = OperationTarget.repositoryTarget(repository.rootPath);
	request.options = metadataOptions;
	auto control = cliOperationControl("Repository metadata");
	repository.appendLog("metadata.start", "");
	auto backendFactory = new DefaultCatalogBackendFactory;
	auto backend = backendFactory.open(OperationTarget.repositoryTarget(repository.rootPath));
	scope (exit)
		backend.close();
	auto result = backend.runOperation(request, control);
	clearOperationProgress();
	if (result.state != OperationState.completed)
	{
		if (result.state == OperationState.cancelled)
			errorLine("Repository metadata operation cancelled.");
		else
			errorLine("Repository metadata operation failed: ", result.error);
		return false;
	}
	auto summary = result.metadataSummary;
	logFLine("Metadata update: %d blobs, %d checksum, %d file type, "
		~ "%d media, %d archive, %d torrent updates, %d failures.",
		summary.blobsVisited, summary.checksumsUpdated,
		summary.fileTypesUpdated, summary.mediaInfoUpdated,
		summary.archivesUpdated, summary.torrentsUpdated, summary.failed);
	repository.appendLog("metadata.complete", format(
		"blobs=%d failed=%d", summary.blobsVisited, summary.failed));
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
		if (gotCtrlC && !control.cancellationRequested)
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
	import core.stdc.stdlib : exit, abort;

	bool do_abort = false;
	debug (all)
		printf("Got signal %d", sig);
	switch (sig)
	{
	case SIGINT:
		if (gotCtrlC)
			exit(1);
		else
			gotCtrlC = true;
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
