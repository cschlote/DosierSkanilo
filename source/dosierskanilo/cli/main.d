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
module dosierskanilo.cli.main;

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

import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.digests;
import dosierskanilo.model.namedbinaryblob;


import dosierarkivo.baseclass;

import dosierskanilo.service.analyze;
import dosierskanilo.cli.commandline;
import dosierskanilo.cli.logging;
import dosierskanilo.service.scanning;
import dosierskanilo.service.storageio;

version (ldc)
{
	import ldc.eh_msvc;
}

/* ----------------------------------------------------------------------- */

/* The dynamic array with all file objects */
NamedBinaryBlob[] dynObjectArray; /// Dynamic Array with our class objects

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
	bool rc;
	version (unittest)
	{
		logLine("Entered main() in Unittest Mode. Do nothing.");
		return 0;
	}
	else
	{
		logFLine("%s %s", appName, appVersion);
		rc = parseCommandLineArgs(args);
		if (rc)
		{
			if (argsArray.argDoMediaSig)
			{
				auto miv = getMediaInfoVersion();
				logLine("Using", miv);
			}
			auto oldhandler = signal(SIGINT, &signalHandler);
			assert(oldhandler != SIG_ERR, "Problem setting signal handler");
			scope (exit)
				signal(SIGINT, oldhandler);

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
	const bool rc_load = readStorageJsonFile(argsArray.argJSONFile, argsArray.argForceOverwrite,
		dynObjectArray);
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
			scanDirTree(argsArray.argScanPath, argsArray.argPickHidden, dynObjectArray, gotCtrlC, argsArray);
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
		const bool rc_dojobs = runScannerJobs(dynObjectArray, gotCtrlC, argsArray);
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
		const bool rc_analyse = analyseData(dynObjectArray, gotCtrlC, argsArray);
		if (!rc_analyse)
			logLine("Data analysis failed.");
	}

	/* Serialize the data */
	if (argsArray.argWriteJSON)
	{
		const bool rc_write = writeStorageJsonFile(argsArray.argJSONFile, dynObjectArray);
		if (!rc_write)
			logLine("Write to storage file failed! Check data!");
	}
	logLine("Scan complete.");
	return true;
}
