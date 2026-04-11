/** Duplicate and missing-file analysis service.
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.service.analyze;

import std.exception;
import std.datetime.systime;
import std.file;
import std.path;
import std.uuid;

import dosierskanilo.logging;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.options;
import dosierskanilo.progress;

/** Do some basic analysis on data.
 *
 * The analysis step removes missing files, identifies same-size groups, checks
 * hashes, merges duplicates, and drops invalidated objects.
 *
 * Params:
 *   dynObjectArray = database objects to analyze and possibly modify.
 *   gotCtrlC = shared abort flag set by the signal handler.
 *   argsArray = parsed command-line options.
 * Returns:
 *   `true` when analysis completed.
 */
bool analyseData(ref NamedBinaryBlob[] dynObjectArray, ref shared(bool) gotCtrlC, ref ArgsArray argsArray)
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

@("analyseData duplicate merge and missing-file drop")
unittest
{
    import std.file : getSize, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "analyze-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        auto file1 = buildPath(root, "dup-1.bin");
        auto file2 = buildPath(root, "dup-2.bin");
        if (exists(file1))
            remove(file1);
        if (exists(file2))
            remove(file2);
        if (exists(root))
            rmdirRecurse(root);
    }

    auto file1 = buildPath(root, "dup-1.bin");
    auto file2 = buildPath(root, "dup-2.bin");
    auto payload = cast(ubyte[])"duplicate payload";
    write(file1, payload);
    write(file2, payload);

    auto obj1 = new NamedBinaryBlob(file1, getSize(file1), Clock.currTime());
    auto obj2 = new NamedBinaryBlob(file2, getSize(file2), Clock.currTime());
    auto missing = new NamedBinaryBlob(buildPath(root, "missing.bin"), 99, Clock.currTime());

    updateDigests(obj1, null);
    updateDigests(obj2, null);

    NamedBinaryBlob[] objs = [obj1, obj2, missing];
    shared(bool) gotCtrlC = false;
    ArgsArray args;
    args.argDropMissing = true;

    assert(analyseData(objs, gotCtrlC, args));
    assert(objs.length == 1);
    assert(objs[0].fileSpecs.length == 2);
    assert(objs[0].checkSums.hasDigests);
}
