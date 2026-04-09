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
	bool argDoFileTypes; ///< Query file types via the `file` utility.
	bool argDoChecksums; ///< Calculate checksums for files.
	bool argDoMediaSig; ///< Calculate media signatures.
	bool argRescanMediaSig; ///< Force media-signature rescans.
	uint argScanArchives; ///< Scan archive contents.
	bool argScanTorrents; ///< Scan torrent contents.
	bool argRunAnalysis; ///< Run duplicate and cleanup analysis.
	bool argDropMissing; ///< Drop missing files from the database.
	bool argWriteJSON; ///< Write the resulting JSON file.
	int argNumberOfThreads = 1; ///< Number of worker threads.
	bool argForceOverwrite; ///< Overwrite an existing JSON file.
	bool argPickHidden; ///< Include hidden files and directories.
	bool argVerboseOutputs; ///< Enable verbose logging.
}

/** Process-global command-line state used by the CLI workflow. */
ArgsArray argsArray;
