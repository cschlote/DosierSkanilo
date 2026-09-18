/** Command-line option state shared with scanner services.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.options;

/** Default extension for JSON storage files. */
enum jsonFileExtension = ".json";

/** Command-line options shared between the CLI and library services. */
struct ArgsArray
{
	string argScanPath; ///< Path to the directory to scan.
	bool argRecursive; ///< Scan directories recursively.
	bool argScanFiles; ///< Scan for new files.
	string argJSONFile; ///< JSON file to read from and write to.
	string argRepositoryPath; ///< Repository root or path below a repository.
	string argImportJSON; ///< JSON file to import into a repository.
	string argExportJSON; ///< JSON file to export from a repository.
	bool argInitRepository; ///< Initialize a `.dosierskanilo` repository.
	bool argDoFileTypes; ///< Query file types via the `file` utility.
	bool argDoChecksums; ///< Calculate checksums for files.
	bool argDoMediaSig; ///< Calculate media signatures.
	bool argRescanMediaSig; ///< Force media-signature rescans.
	uint argScanArchives; ///< Scan archive contents.
	bool argScanTorrents; ///< Scan torrent contents.
	bool argRunAnalysis; ///< Run duplicate and cleanup analysis.
	bool argRunMetadata; ///< Run repository metadata extraction.
	bool argShowInfo; ///< Show repository metadata and catalog counts.
	bool argList; ///< List repository blobs.
	bool argDuplicates; ///< List duplicate blob groups.
	uint argDuplicateLimit = 100; ///< Maximum number of duplicate groups.
	string argQueryText; ///< Filter repository paths or SHA1 values.
	uint argQueryLimit = 50; ///< Maximum number of listed blobs.
	uint argQueryOffset; ///< Number of matching blobs to skip.
	bool argQueryVideo; ///< Require video metadata.
	bool argQueryAudio; ///< Require audio metadata.
	bool argQueryImage; ///< Require image metadata.
	bool argQueryTextStream; ///< Require text/subtitle metadata.
	bool argQueryFileType; ///< Require file type metadata.
	bool argQueryArchive; ///< Require archive metadata.
	bool argQueryTorrent; ///< Require torrent metadata.
	string argOutputFormat = "table"; ///< Repository query output format.
	bool argDropMissing; ///< Drop missing files from the database.
	bool argWriteJSON; ///< Write the resulting JSON file.
	int argNumberOfThreads = 1; ///< Number of worker threads.
	bool argForceOverwrite; ///< Overwrite an existing JSON file.
	bool argReplaceCatalog; ///< Replace an existing repository catalog on import.
	bool argPickHidden; ///< Include hidden files and directories.
	bool argVerboseOutputs; ///< Enable verbose logging.
	bool argVersion; ///< Show the application version.
}

@("options defaults")
unittest
{
	import std.string : empty;
	
	ArgsArray opts;
	assert(opts.argNumberOfThreads == 1);
	assert(opts.argScanArchives == 0);
	assert(opts.argJSONFile.empty);
	assert(opts.argScanPath.empty);
}
