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
			if (!configureArchiveCache(options))
				return 1;
			noticeFLine("%s %s", appName, appVersion);
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

/** Import a JSON catalog into a repository. */
bool executeRepositoryImport(CatalogBackend backend, string repositoryRoot,
	ArgsArray options)
{
	logLine("Catalog phase: import JSON.");
	logLineVerbose("Importing into catalog root: ", repositoryRoot);
	JsonImportOptions importOptions;
	importOptions.force = options.argReplaceCatalog;
	auto control = cliOperationControl("Catalog import");
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
	auto control = cliOperationControl(options.argScanFiles
		? "Catalog scan" : "Catalog analysis");
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
 */
private bool executeJsonCatalogOperation(ArgsArray options, OperationTarget target)
{
	auto control = cliOperationControl(options.argScanFiles
		? "Catalog scan" : "Catalog analysis");
	OperationResult result;
	if (options.argScanFiles)
		result = runOperation(scanRequestFromCli(options, target), control);
	else
		result = runOperation(analysisRequestFromCli(options, target), control);
	clearOperationProgress();
	return reportCatalogOperationResult("Catalog", options, result);
}

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
	request.metadataOptions = metadataOptionsFromCli(options);
	return request;
}

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
	return request;
}

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
			errorLine(backendName ~ " operation failed: ", result.error);
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

/** Export the repository catalog when requested. */
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
		logLineVerbose("Export path prefix: ", options.argExportPath);
	CatalogExportOptions exportOptions;
	exportOptions.outputPath = exportPath;
	exportOptions.format = CatalogExportFormat.jsonV5;
	auto control = cliOperationControl("Catalog export");
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

/** Build the shared catalog filter from query command-line options. */
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

/** Collect all matching file references, including indexed archive members. */
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

/** Original member name without the canonical occurrence suffix. */
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

/** Print a blob page for JSON catalogs without a bound filesystem root. */
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

/** Print one bounded, catalog-side filtered page of file references. */
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

/** Print duplicate groups for JSON catalogs without a bound root. */
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

/** Print duplicate groups without modifying catalog contents. */
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
