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
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
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

import dosierskanilo_cli.commandline;

version (ldc)
{
	import ldc.eh_msvc;
}

/* ----------------------------------------------------------------------- */

/* The global wrapper with all file objects and shared metadata */
NamedBinaryBlobCatalog dynObjectWrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []); /// Global data wrapper

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
			logFLine("%s %s", appName, appVersion);
			if (options.argDoMediaSig)
			{
				auto miv = getMediaInfoVersion();
				logLine("Using", miv);
			}
			auto oldhandler = signal(SIGINT, &signalHandler);
			assert(oldhandler != SIG_ERR, "Problem setting signal handler");
			scope (exit)
				signal(SIGINT, oldhandler);

			bool rc;
			if (parsed.command != CliCommand.legacyJson)
				rc = executeRepositoryOperation(options);
			else if (options.argInitRepository || !options.argRepositoryPath.empty
				|| !options.argImportJSON.empty || !options.argExportJSON.empty)
				rc = executeRepositoryOperation(options);
			else
				rc = executeFileScannerOperation(options);
			return rc ? 0 : 1;
		}
	}
}

/** Execute a SQLite repository operation selected by the CLI options. */
bool executeRepositoryOperation(ArgsArray options)
{
	try
	{
		auto repositoryPath = options.argRepositoryPath;
		if (repositoryPath.empty)
			repositoryPath = options.argScanPath;

		Repository repository;
		if (options.argInitRepository)
			repository = Repository.initialize(repositoryPath);
		else
		repository = Repository.open(repositoryPath);
		repository.appendLog("repository.open", repositoryPath);
		if (options.argShowInfo)
		{
			executeRepositoryInfo(repository);
			repository.close();
			return true;
		}

		if (!options.argImportJSON.empty)
		{
			logLine("Repository phase: import JSON.");
			repository.appendLog("json.import", options.argImportJSON);
			JsonImportOptions importOptions;
			importOptions.force = options.argForceOverwrite;
			repository.importJson(options.argImportJSON, importOptions);
			logFLine("Imported JSON catalog '%s'.", options.argImportJSON);
		}

		if (options.argScanFiles)
		{
			logLine("Repository phase: scan filesystem.");
			repository.appendLog("scan.start", repository.rootPath);
			RepositoryScanOptions scanOptions;
			scanOptions.recursive = options.argRecursive;
			scanOptions.pickHidden = options.argPickHidden;
			scanOptions.dropMissing = options.argDropMissing;
			auto summary = repository.scan(scanOptions);
			logFLine("Repository scan: %d files, %d added, %d changed, %d missing.",
				summary.filesFound, summary.filesAdded, summary.filesChanged,
				summary.filesMissing);
			repository.appendLog("scan.complete", format(
				"files=%d added=%d changed=%d missing=%d", summary.filesFound,
				summary.filesAdded, summary.filesChanged, summary.filesMissing));
		}

		if (options.argRunAnalysis)
		{
			logLine("Repository phase: SQL analysis.");
			repository.appendLog("analysis.start", "");
			RepositoryAnalysisOptions analysisOptions;
			analysisOptions.dropMissing = options.argDropMissing;
			auto summary = repository.analyze(analysisOptions);
			logFLine("Repository analysis: %d missing, %d dropped, %d duplicate "
				~ "groups, %d merged blobs, %d orphaned blobs.",
				summary.missingFiles, summary.droppedFiles,
				summary.duplicateGroups, summary.mergedBlobs,
				summary.orphanedBlobs);
			repository.appendLog("analysis.complete", format(
				"missing=%d dropped=%d groups=%d merged=%d orphaned=%d",
				summary.missingFiles, summary.droppedFiles,
				summary.duplicateGroups, summary.mergedBlobs,
				summary.orphanedBlobs));
		}

		if (options.argRunMetadata || options.argDoChecksums
			|| options.argDoFileTypes || options.argDoMediaSig
			|| options.argScanArchives || options.argScanTorrents)
		{
			executeRepositoryMetadata(repository, options);
		}

		auto exportPath = options.argExportJSON;
		if (exportPath.empty && options.argWriteJSON)
			exportPath = options.argJSONFile;
		if (!exportPath.empty)
		{
			logLine("Repository phase: export JSON.");
			repository.appendLog("json.export", exportPath);
			repository.exportJson(exportPath);
			logFLine("Exported repository JSON to '%s'.", exportPath);
		}
		repository.close();
		return true;
	}
	catch (Exception ex)
	{
		logLine("Repository operation failed: ", ex.msg);
		return false;
	}
}

/** Print repository metadata and current catalog counts. */
void executeRepositoryInfo(Repository repository)
{
	auto info = repository.info;
	logFLine("Repository root: %s", info.rootPath);
	logFLine("Database: %s", repository.databasePath);
	logFLine("Schema version: %d", info.schemaVersion);
	logFLine("Created: %s", info.createdAt);
	logFLine("Updated: %s", info.updatedAt);
	logFLine("Blobs: %d", repository.blobCount);
}

/** Execute the selected metadata extractors against a repository. */
void executeRepositoryMetadata(Repository repository, ArgsArray options)
{
	logLine("Repository phase: metadata extraction.");
	repository.appendLog("metadata.start", "");
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
	auto summary = repository.updateMetadata(metadataOptions);
	logFLine("Metadata update: %d blobs, %d checksum, %d file type, "
		~ "%d media, %d archive, %d torrent updates, %d failures.",
		summary.blobsVisited, summary.checksumsUpdated,
		summary.fileTypesUpdated, summary.mediaInfoUpdated,
		summary.archivesUpdated, summary.torrentsUpdated, summary.failed);
	repository.appendLog("metadata.complete", format(
		"blobs=%d failed=%d", summary.blobsVisited, summary.failed));
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

/** Scan a directory (optionally recursively)
 *
 * Based on the commandline options scan a directory (tree) and calculate a
 * checksum on it.
 */
bool executeFileScannerOperation(ArgsArray options)
{

	/* Read the JSON file, if existent */
	const bool rc_load = readStorageJsonFile(options.argJSONFile, options.argForceOverwrite,
		dynObjectWrapper);
	if (!rc_load)
	{
		logLine("Abort program. Use -f to force overwriting of output file.");
		return false;
	}

	/* Scan directory - here we just collect the filenames. Any new name is added
	   as a new node to the array of object blobs.
	 */
	if (options.argScanFiles)
	{
		import std.algorithm.iteration : fold;

		const bool rc_scandirtree =
			scanDirTree(options.argScanPath, options.argPickHidden, dynObjectWrapper.dataArray, gotCtrlC, options);
		if (!rc_scandirtree)
		{
			logLine("Failed to scan the directory tree.");
			return false;
		}
	}

	/* The next section is running the real time consuming jobs.*/
	try
	{
		/* Execute the checksum and MediaInfo jobs for each file. */
		const bool rc_dojobs = runScannerJobs(dynObjectWrapper.dataArray, gotCtrlC, options);
		if (!rc_dojobs)
			logLine("Failed to run all scanner jobs.");
	}
	catch (Exception e)
	{
		logLine("Something happened while scanning and an exception was thrown.");
		auto emergencySaveName = buildPath(thisExePath.dirName, ".crash_save.json");
		logFLine("Serialize Array of Objects to temporary file: %s", emergencySaveName);
		serializeDataClassWrapperFile(emergencySaveName, dynObjectWrapper);
		logLine("Exception message: ", e.msg);
		logLine("File: ", e.file);
		logLine("Line: ", e.line);
		logLine("Stacktrace:\n", e.toString);
		logLine("The program will now stop.");
		return false;
	}

	/* Do data analysis on data */
	if (options.argRunAnalysis)
	{
		/* Do something useful on data */
		const bool rc_analyse = analyseData(dynObjectWrapper.dataArray, gotCtrlC, options);
		if (!rc_analyse)
			logLine("Data analysis failed.");
	}

	/* Serialize the data */
	if (options.argWriteJSON)
	{
		const bool rc_write = writeStorageJsonFile(options.argJSONFile, dynObjectWrapper);
		if (!rc_write)
			logLine("Write to storage file failed! Check data!");
	}
	logLine("Scan complete.");
	return true;
}
