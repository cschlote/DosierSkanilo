/** Data Scanner
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.service.scanning;

import std.array;
import std.exception;
import std.datetime.systime;
import std.file;
import std.parallelism;
import std.path;
import std.string;
import std.stdio;
import std.uuid;

import dosierskanilo.logging;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.options;
import dosierskanilo.progress;

/** Scan a directory tree and collect data
 *
 *  Scan a directory tree and collect the basic file properties,
 *  like size or last modification data.
 *  Try to find an existing NamedBinaryBlob object in the dynamic array, or
 *  create a container object and add it to the dynamic Array.
 *
 *  Files are updated in-place when only metadata changes; otherwise a new blob
 *  node is created so history is preserved for multi-file entries.
 *
 * Params:
 *   scanPath = path to directory for the scan.
 *   pickHidden = if true, hidden files and directories are also scanned.
 *   dynObjectArray = database objects collected so far.
 *   gotCtrlC = shared abort flag set by the signal handler.
 *   argsArray = parsed command-line options.
 * Returns:
 *   `true` if the scan completed.
 */
bool scanDirTree(string scanPath, bool pickHidden = false, ref NamedBinaryBlob[] dynObjectArray, ref shared(
        bool) gotCtrlC, ref ArgsArray argsArray)
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
                    logFLine("\nSize mismatch for file '%s': %d != %d", dirEntry.name, currentBlob.fileSize, dirEntry
                            .size);
                    needNewNode = true;
                }
                if (fspec.timeLastModified != dirEntry.timeLastModified.toISOExtString)
                {
                    logFLine("\nModification time mismatch for file '%s': %s != %s", dirEntry.name,
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

/** Execute scanner jobs on collected files.
 *
 * This runs the optional signature extraction passes for checksums, file
 * types, media signatures, archives, and torrent metadata.
 *
 * Params:
 *   dynObjectArray = database objects to enrich.
 *   gotCtrlC = shared abort flag set by the signal handler.
 *   argsArray = parsed command-line options.
 * Returns:
 *   `true` when all configured jobs finished.
 */
bool runScannerJobs(ref NamedBinaryBlob[] dynObjectArray, ref shared(bool) gotCtrlC, ref ArgsArray argsArray)
{
    bool rc = true;
    if (argsArray.argDoChecksums
        || argsArray.argDoFileTypes
        || argsArray.argDoMediaSig
        || argsArray.argScanArchives
        || argsArray.argScanTorrents)
    {
        logLine("(Use Ctrl-C once to abort hashing and save data)");

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
                if (argsArray.argScanArchives && obj.archiveSpecs is null)
                {
                    obj.task_archiveScan = task!updateArchives(obj, argsArray.argRescanMediaSig, argsArray.argScanArchives > 1, &gotCtrlC, cast(ProgressCallBack*)null);
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
                if (argsArray.argScanArchives && obj.archiveSpecs is null)
                {
                    ProgressCallBack cb = ProgressCallBack(&progressCallBack);

                    updateArchives(obj, false, argsArray.argScanArchives > 1, &gotCtrlC, &cb);
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

@("scanDirTree and runScannerJobs")
unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "scanning-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(buildPath(root, "visible.jpg")))
            remove(buildPath(root, "visible.jpg"));
        if (exists(buildPath(root, ".hidden.jpg")))
            remove(buildPath(root, ".hidden.jpg"));
        if (exists(root))
            rmdirRecurse(root);
    }

    auto visible = buildPath(root, "visible.jpg");
    auto hidden = buildPath(root, ".hidden.jpg");
    write(visible, cast(ubyte[])[0, 1, 2, 3, 4, 5]);
    write(hidden, cast(ubyte[])[9, 8, 7]);

    NamedBinaryBlob[] objs;
    shared(bool) gotCtrlC = false;
    ArgsArray args;
    args.argDoChecksums = true;
    args.argDoFileTypes = true;
    args.argDoMediaSig = true;

    assert(scanDirTree(root, false, objs, gotCtrlC, args));
    assert(objs.length == 1);
    assert(objs[0].getFirstFileName == visible);
    assert(objs[0].getExistingFiles.length == 1);

    write(visible, cast(ubyte[])[0, 1, 2, 3, 4, 5, 6, 7]);
    assert(scanDirTree(root, false, objs, gotCtrlC, args));
    assert(objs.length == 1);
    assert(objs[0].fileSize == 8);

    assert(runScannerJobs(objs, gotCtrlC, args));
    assert(objs[0].checkSums.hasDigests);
    assert(!objs[0].fileType.empty);
    assert(objs[0].mediaInfoSig !is null);
}

@("runScannerJobs archive and torrent")
unittest
{
    import std.conv : to;
    import std.file : getcwd, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "scanning-archive-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        auto zipPath = buildPath(root, "jobs.zip");
        auto payload = buildPath(root, "payload.txt");
        if (exists(zipPath))
            remove(zipPath);
        if (exists(payload))
            remove(payload);
        if (exists(root))
            rmdirRecurse(root);
    }

    auto payload = buildPath(root, "payload.txt");
    write(payload, "archive payload\n");
    auto zipPath = buildPath(root, "jobs.zip");
    auto zipCreate = execute(["zip", "-q", "-j", zipPath, payload]);
    assert(zipCreate.status == 0, zipCreate.output);

    auto torrentPath = "test/example.torrent";
    NamedBinaryBlob[] objs = [
        new NamedBinaryBlob(zipPath, getSize(zipPath), Clock.currTime()),
        new NamedBinaryBlob(torrentPath, getSize(torrentPath), Clock.currTime()),
    ];
    shared(bool) gotCtrlC = false;
    ArgsArray args;
    args.argScanArchives = 1;
    args.argScanTorrents = true;
    args.argNumberOfThreads = 2;

    assert(runScannerJobs(objs, gotCtrlC, args));
    assert(objs[0].archiveSpecs !is null);
    assert(objs[0].archiveSpecs.length > 0);
    assert(objs[1].torrentInfo !is null);
}

@("runScannerJobs threaded")
unittest
{
    import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "scanning-threaded-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        auto picture = buildPath(root, "threaded.jpg");
        if (exists(picture))
            remove(picture);
        if (exists(root))
            rmdirRecurse(root);
    }

    auto picture = buildPath(root, "threaded.jpg");
    write(picture, cast(ubyte[])[1, 2, 3, 4, 5, 6, 7, 8]);

    NamedBinaryBlob[] objs;
    shared(bool) gotCtrlC = false;
    ArgsArray args;
    args.argDoChecksums = true;
    args.argDoFileTypes = true;
    args.argDoMediaSig = true;
    args.argNumberOfThreads = 2;

    assert(scanDirTree(root, false, objs, gotCtrlC, args));
    assert(objs.length == 1);
    assert(runScannerJobs(objs, gotCtrlC, args));
    assert(objs[0].checkSums.hasDigests);
    assert(!objs[0].fileType.empty);
    assert(objs[0].mediaInfoSig !is null);
}
