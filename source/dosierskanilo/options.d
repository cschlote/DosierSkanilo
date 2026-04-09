/** Command-line option state shared with scanner services.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.options;

enum jsonFileExtension = ".json";

struct ArgsArray
{
	string argScanPath;
	bool argRecursive;
	bool argScanFiles;
	string argJSONFile;
	bool argDoFileTypes;
	bool argDoChecksums;
	bool argDoMediaSig;
	bool argRescanMediaSig;
	uint argScanArchives;
	bool argScanTorrents;
	bool argRunAnalysis;
	bool argDropMissing;
	bool argWriteJSON;
	int argNumberOfThreads = 1;
	bool argForceOverwrite;
	bool argPickHidden;
	bool argVerboseOutputs;
}

ArgsArray argsArray;
