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
module appmain;

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

import dosierskanilo.namedbinaryblob;
import dosierskanilo.digests;
import dosierskanilo.mediainfosig;
import dosierskanilo.scannerpolicy;

import dosierarkivo.baseclass;

import commandline;
import logging;
import storageio;

version (ldc)
{
	import ldc.eh_msvc;
}

/* ----------------------------------------------------------------------- */

/* The dynamic array with all file objects */
NamedBinaryBlob[] dynObjectArray; /// Dynamic Array with our class objects

/* Custom CTRL-C handler for a smooth abort of running scan operation */
shared bool gotCtrlC; /// Set in handler

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
	bool rc;
	version (unittest)
	{
		logLine("Entered main() in Unittest Mode. Do nothing.");
		return 0;
	}
	else
	{
		logLine("DosierSkanilo V0.0.0");
		rc = parseCommandLineArgs(args);
		if (rc)
		{
			if (argsArray.argDoMediaSig)
			{
				auto miv = getMediaInfoVersion();
				logLine("Using", miv);
			}

			rc = executeFileScannerOperation();
		}
	}
	return rc ? 0 : 1; // Return a a SHELL (!) exit code here.
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
bool executeFileScannerOperation()
{

	/* Read the JSON file, if existent */
	const bool rc_load = readStorageFile();
	if (!rc_load)
	{
		logLine("Abort program. Use -f to force overwriting of output file.");
		return false;
	}

	/* Scan directory - here we just collect the filenames. Any new name is added
	   as a new node to the array of object blobs.
	 */
	if (argsArray.argScanFiles)
	{
		import std.algorithm.iteration : fold;

		const bool rc_scandirtree =
			scanDirTree(argsArray.argScanPath, argsArray.argPickHidden);
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
		const bool rc_dojobs = runScannerJobs();
		if (!rc_dojobs)
			logLine("Failed to run all scanner jobs.");
	}
	catch (Exception e)
	{
		logLine("Something happened while scanning and an exception was thrown.");
		auto emergencySaveName = buildPath(thisExePath.dirName, ".crash_save.json");
		logFLine("Serialize Array of Objects to temporary file: %s", emergencySaveName);
		serializeDataClassArrayFile(emergencySaveName, dynObjectArray);
		logLine("Exception message: ", e.msg);
		logLine("File: ", e.file);
		logLine("Line: ", e.line);
		logLine("Stacktrace:\n", e.toString);
		logLine("The program will now stop.");
		return false;
	}

	/* Do data analysis on data */
	if (argsArray.argRunAnalysis)
	{
		/* Do something useful on data */
		const bool rc_analyse = analyseData();
		if (!rc_analyse)
			logLine("Data analysis failed.");
	}

	/* Serialize the data */
	if (argsArray.argWriteJSON)
	{
		const bool rc_write = writeStorageFile();
		if (!rc_write)
			logLine("Write to storage file failed! Check data!");
	}
	logLine("Scan complete.");
	return true;
}

/** Read data in storage file
 *
 *  Depending on configuration, the data is loaded from some file,
 *  deserialized again.
 */
bool readStorageFile()
{
	return readStorageJsonFile(argsArray.argJSONFile, argsArray.argForceOverwrite,
		dynObjectArray);
}

/** Scan a directory tree and collect data
 *
 *  Scan a directory tree and collect the basic file properties,
 *  like size or last modification data.
 *  Try to find an existing NamedBinaryBlob object in the dynamic array, or
 *  create a container object and add it to the dynamic Array.
 *
 *  Param:
 *   scanPath - Path to directory for the scan
 *   pickHidden - if true, hidden files and directories are also scanned
 *
 *  Returns true, if all Files were scanned, otherwise false is returned.
 */
bool scanDirTree(string scanPath, bool pickHidden = false)
{
	const bool rc = true;

	/* Some statistical output */
	size_t totalsize = 0; // Total file size scanned
	ulong totaldirs = 0; // Total directory seen
	ulong totalfiles = 0; // Total files seen
	ulong totaldbfiles()
	{
		return dynObjectArray.length;
	} // Total files in database

	logFLine("Scanning Directory : %s", scanPath);

	printProgress(0, totaldbfiles, null);

	// We get a lazy range of DirEntrys here, no length known up-front.
	auto foundDirEntries =
		dirEntries(scanPath, argsArray.argRecursive ? SpanMode.depth : SpanMode.shallow);

	foreach (DirEntry dirEntry; foundDirEntries)
	{
		import std.algorithm.searching : find;
		import std.algorithm : filter;
		import std.path : baseName;

		printProgress(totalfiles, totaldbfiles, dirEntry.name);

		if (pickHidden == false && dirEntry.name.baseName.startsWith("."))
			continue; // Skip hidden files and directories

		if (isFile(dirEntry.name))
		{
			totalfiles++;

			NamedBinaryBlob currentBlob;

			// Find all nodes with same filename
			alias matcher = (a) => a.hasFileName(dirEntry.name);
			auto existingNodes = dynObjectArray.filter!(matcher).array;
			// There should be at most one existing node for a filename
			enforce(existingNodes.length <= 1,
				"\nFound %d binary blobs for filename '%s'."
					.format(existingNodes.length, dirEntry.name));

			// A local function to add a new blob object from file entry
			void addNewBlob()
			{
				logFLineVerbose("Add new Blob object for file '%s'.", dirEntry.name);
				currentBlob =
					new NamedBinaryBlob(dirEntry.name, dirEntry.size, dirEntry.timeLastModified);
				dynObjectArray ~= currentBlob;
				totalsize += dirEntry.size;
			}

			// The filename is not yet in the database
			if (existingNodes.empty)
			{
				addNewBlob();
			}
			else // The filename is already in the database
			{
				currentBlob = existingNodes[0]; // Already checked above for length <= 1

				auto fspec = currentBlob.getFileSpec(dirEntry.name);
				enforce(fspec !is null, "\nFileSpec not found for existing filename.");
				enforce(fspec.fileName == dirEntry.name, "\nName mismatch.");

				bool needNewNode = false;

				// Check, if the file has changed in size or modification time
				if (currentBlob.fileSize != dirEntry.size)
				{
					logFLine("\nSize mismatch for file '%s': %d != %d", dirEntry.name, currentBlob.fileSize, dirEntry.size);
					needNewNode = true;
				}
				if (fspec.timeLastModified != dirEntry.timeLastModified.toISOExtString)
				{
					logFLine("\nModification time mismatch for file '%s': %s != %s"
							, dirEntry.name,
								fspec.timeLastModified,
								dirEntry.timeLastModified.toISOExtString);
					needNewNode = true;
				}

				// We need to create a new node, if something has changed
				if (needNewNode)
				{
					// Check if we have multiple FileSpecs in the current blob
					if (currentBlob.fileSpecs.length > 1)
					{
						// Delete fileSpec from the current blob object
						auto delspec = currentBlob.deleteFileSpec(dirEntry.name);
						enforce(delspec !is null,
							"\nFailed to delete FileSpec '%s' from existing blob."
								.format(dirEntry.name));
						enforce(delspec.fileName == dirEntry.name,
							"\nDeleted FileSpec name mismatch.");
						enforce(currentBlob.getFileSpec(dirEntry.name) is null,
							"\nFileSpec still found after deletion.");
						enforce(currentBlob.fileSpecs.length != 0,
							"\nFileSpecs length is 0 after deletion of '%s'."
								.format(dirEntry.name));

						// Add file as a new BinaryBlob object, might be new file or
						// different in its contents
						addNewBlob();
						enforce(currentBlob.getFileSpec(dirEntry.name) !is null,
							"\nNewly added Blob has no FileSpec for '%s'."
								.format(dirEntry.name));
					}
					else // Only a single FileSpec in the current blob - update blob
					{
						logFLineVerbose(
							"Update existing Blob object for file '%s'.", dirEntry.name);
						currentBlob.fileSize = dirEntry.size;
						fspec.timeLastModified = dirEntry.timeLastModified.toISOExtString;

						totalsize += dirEntry.size;
					}

				}

			}
		}
		else
		{
			totaldirs++;
		}
	}
	printProgress(totalfiles, totaldbfiles, null);
	logLine();
	logLine("Scanner found on '", scanPath, "'.");
	logLine("   Number of files in database := ", dynObjectArray.length);
	logLine("   Number of files found :=", totalfiles);
	logLine("   Number of dirs  found :=", totaldirs);
	logLineVerbose("Overall data sizes in database:");
	logFLineVerbose("  %15d Bytes used.", totalsize);
	logFLineVerbose("  %15d MB used.", totalsize / 1_000_000);
	logFLineVerbose("  %15d MiB used.", totalsize / (1024 * 1024));
	stdout.flush();
	return rc;
}

/** Execute scanner jobs on collected files
 *
 *  Here we execute a set of jobs, whose results are added as 'signatures'
 *  to the object.
 */
bool runScannerJobs()
{
	bool rc = true;
	if (argsArray.argDoChecksums
		|| argsArray.argDoFileTypes
		|| argsArray.argDoMediaSig
		|| argsArray.argScanArchives
		|| argsArray.argScanTorrents)
	{
		logLine("(Use Ctrl-C once to abort hashing and save data)");
		auto oldhandler = signal(SIGINT, &signalHandler);
		assert(oldhandler != SIG_ERR, "Problem setting signal handler");
		scope (exit)
			signal(SIGINT, oldhandler);

		/* Use multi-threaded approach */
		if (argsArray.argNumberOfThreads > 1)
		{
			TaskPool myTaskPool = new TaskPool(argsArray.argNumberOfThreads);
			logLine("Add jobs for all entries with no hash data or media signature to taskPool.");
			foreach (i, obj; dynObjectArray)
			{
				import std.file : exists;

				if (obj.getFirstExistingFileName.empty)
					continue;

				// printProgress(i, dynObjectArray.length, obj.getFirstFileName);

				if (argsArray.argDoChecksums && obj.checkSums.hasDigests == false)
				{
					ProgressCallBack cb = ProgressCallBack(&progressCallBack);
					obj.task_hashme = task!updateDigests(obj, &gotCtrlC, &cb);
					myTaskPool.put(obj.task_hashme);
				}
				if (argsArray.argDoFileTypes && obj.fileType.empty)
				{
					obj.task_filetype = task!updateFileType(obj);
					myTaskPool.put(obj.task_filetype);
				}
				if (argsArray.argDoMediaSig && (obj.mediaInfoSig is null ||
						argsArray.argRescanMediaSig))
				{
					obj.task_mediasig = task!updateMediaInfo(obj,
						argsArray.argRescanMediaSig);
					myTaskPool.put(obj.task_mediasig);
				}
				if (shouldQueueArchiveScanJob(argsArray.argScanArchives, obj))
				{
					obj.task_archiveScan = task!updateArchives(obj);
					myTaskPool.put(obj.task_archiveScan);
				}
				if (argsArray.argScanTorrents && obj.torrentInfo is null)
				{
					obj.task_torrentscan = task!updateTorrentInfo(obj);
					myTaskPool.put(obj.task_torrentscan);
				}
			}
			if (gotCtrlC)
			{
				logLine("Received Ctrl-C - abort jobs");
				myTaskPool.stop();
				rc = false;
			}
			else
			{
				logLine("\nNow collect the results, and process jobs instead of waiting.");
				foreach (i, obj; dynObjectArray)
				{
					auto existingFiles = obj.getExistingFiles;
					obj.fileSpecs = existingFiles;
					if (existingFiles.length == 0)
						continue;

					printProgress(i, dynObjectArray.length, obj.getFirstFileName);

					if (obj.task_hashme)
					{
						obj.task_hashme.workForce();
					}
					if (obj.task_filetype)
					{
						obj.task_filetype.workForce();
					}
					if (obj.task_mediasig)
					{
						obj.task_mediasig.workForce();
					}
					if (obj.task_archiveScan)
					{
						obj.task_archiveScan.workForce();
					}
					if (obj.task_torrentscan)
					{
						obj.task_torrentscan.workForce();
					}

					if (gotCtrlC)
					{
						logLine("Received Ctrl-C - abort jobs");
						myTaskPool.stop();
						rc = false;
						break;
					}
				}
			}
			logLine();

			logLine("Waiting for checksum threads to terminate.");
			myTaskPool.finish(true);
			/* Important: Stop worker threads. Otherwise the program will hang on exit. */
			myTaskPool.stop();
		}

		else /* Singlethreaded approach */
		{
			logLine("Calculate the checksums and mediasigs, if not yet done. (single threaded)");
			foreach (i, obj; dynObjectArray)
			{
				auto existingFiles = obj.getExistingFiles;
				obj.fileSpecs = existingFiles;
				if (existingFiles.length == 0)
					continue;

				printProgress(i, dynObjectArray.length, obj.getFirstFileName);

				if (argsArray.argDoChecksums && obj.checkSums.hasDigests == false)
				{
					ProgressCallBack cb = ProgressCallBack(&progressCallBack);

					updateDigests(obj, &gotCtrlC, &cb);
				}
				if (argsArray.argDoFileTypes && obj.fileType.empty)
				{
					updateFileType(obj, false);
				}
				if (argsArray.argDoMediaSig && (obj.mediaInfoSig is null ||
						argsArray.argRescanMediaSig))
				{
					updateMediaInfo(obj, argsArray.argRescanMediaSig);
				}
				if (shouldQueueArchiveScanJob(argsArray.argScanArchives, obj))
				{
					ProgressCallBack cb = ProgressCallBack(&progressCallBack);

					updateArchives(obj, false,&gotCtrlC, &cb);
				}
				if (argsArray.argScanTorrents && obj.torrentInfo is null)
				{
					updateTorrentInfo(obj, false);
				}

				if (gotCtrlC)
				{
					logLine("Received Ctrl-C - abort jobs");
					rc = false;
					break;
				}
			}
			printProgress(dynObjectArray.length, dynObjectArray.length, "");
			write("\n");
		}
	}
	stdout.flush();
	return rc;
}

/** Do some basic analysis on data
*/
private bool analyseData()
{
	bool rc;
	logLine("Analyse Array of Objects");

	/* ------------------------------------------------------------------- */

	{
		NamedBinaryBlob[] dynObjectArray2 = cleanupDataClassObjs(dynObjectArray);
		auto droppedFilesCnt = dynObjectArray.length - dynObjectArray2.length;
		if (argsArray.argDropMissing)
		{
			logFLine("    Dropped %d none existing files.", droppedFilesCnt);
			dynObjectArray = dynObjectArray2;
		}
		else
		{
			logFLine("    Found %d none existing files.", droppedFilesCnt);
			if (argsArray.argVerboseOutputs)
			{
				foreach (obj; dynObjectArray)
				{
					if (obj.getExistingFiles.length == 0)
						logLine("      ?: ", obj.getFirstFileName);
				}
			}
		}
	}

	/* ------------------------------------------------------------------- */
	logLine("  Map sizes and file objects... (checksummed files only.)");
	NamedBinaryBlob[][size_t] sizeMap;
	{
		// Map all object by size to sizeMapTemp assoc array
		NamedBinaryBlob[][size_t] sizeMapTemp;
		foreach (v; dynObjectArray)
			if (v.checkSums.hasDigests)
				sizeMapTemp[v.fileSize] ~= v;

		// Now filter all elements with multiple files of same size
		foreach (v; sizeMapTemp.keys)
			if (sizeMapTemp[v].length > 1)
				sizeMap[v] ~= sizeMapTemp[v];
	}
	logFLine("  we found file sets of same size : %d", sizeMap.length);

	/* ------------------------------------------------------------------- */
	logLine("  Check for duplicate objects...");
	NamedBinaryBlob[] mergedObjs = [];
	foreach (someSize; sizeMap.keys)
	{
		// if (someSize == 0) // Unhandled case
		// 	continue;

		auto objs = sizeMap[someSize];

		logFLineVerbose("    Update the digests for all %d files with size %d.", objs.length, someSize);
		foreach (obj; objs)
		{
			logLineVerbose("    ", obj.getFirstFileName);
			ProgressCallBack cb = ProgressCallBack(&progressCallBack);
			obj.updateDigests(&gotCtrlC, &cb);
		}

		logFLineVerbose("    Map files of size %d by their SHA1 digests...", someSize);
		NamedBinaryBlob[][string] digestMap = null;
		foreach (obj; objs)
		{
			assert(obj.checkSums.sha1sum_b64, "No SHA1 checksum?");
			digestMap[obj.checkSums.sha1sum_b64] ~= obj;
		}
		foreach (digestobjs; digestMap)
		{
			if (digestobjs.length > 1)
			{
				logFLine("  Duplicates found for size %d, SHA1 hash %s:",
					digestobjs[0].fileSize, digestobjs[0].checkSums.sha1sum_b64);
				foreach (dobj; digestobjs)
					logLine("      ?: ", dobj.getFirstFileName);
				// Now merge the identical binary blobs but with different
				// name into a single data class object.
				try
				{
					auto mergedObj = mergeDataClassObjects(digestobjs);
					mergedObjs ~= mergedObj;
					invalidateDataClassObjs(digestobjs);
				}
				catch (Exception ex)
				{
					logFLine("      Exception: Checksum mismatch?\n%s", ex.msg);
				}
			}
			else if (digestobjs.length == 1)
			{
				// logFLine("  No duplicates found for size %d, SHA1 hash %s:",
				// 	digestobjs[0].fileSize, digestobjs[0].sha1sum_b64);
				// logLine("      ?: ", objs[0].getFirstFileName);
			}
			else
				assert(false, "Shouldn't happen.");
		}
	}
	if (mergedObjs.length)
	{
		logFLine("    Add %d merged nodes.", mergedObjs.length);
		dynObjectArray ~= mergedObjs;
	}

	/* ------------------------------------------------------------------- */
	logLine("  Drop invalidated objects.");
	{
		NamedBinaryBlob[] dynObjectArray3 = cleanupDataClassObjs(dynObjectArray);
		auto droppedFilesCnt2 = dynObjectArray.length - dynObjectArray3.length;
		logFLine("    Dropped %d invalidated nodes.", droppedFilesCnt2);
		dynObjectArray = dynObjectArray3;
	}
	/* ------------------------------------------------------------------- */
	rc = true;
	return rc;
}

/** Write scanned data to some storage file
 *
 *  Depending on configuration, the data is serialized to some file.
 */
private bool writeStorageFile()
{
	return writeStorageJsonFile(argsArray.argJSONFile, dynObjectArray);
}
