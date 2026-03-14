/** Command-line parsing and progress output helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module commandline;

import std.conv;
import std.exception;
import std.getopt;
import std.file;
import std.path;
import std.process;
import std.range;
import std.string;

import logging;
import core.internal.lifetime;

enum jsonFileExtension = ".json"; /// The file extension we use for JSON files

immutable string helpText = q"EOS

This is a small utility to scan a directory and collect all files
found within. Each file with same size and same checksums are considered
the be the same.

It also utilizes the 'file' utility to determine filetypes, and can
calculate media signatures for audio and video files.

It can store its results in a JSON file, and read them back later on. It has
also some analysis functions to find duplicate files, missing files, etc.

EOS";

/** This struct holds all commandline args */
struct ArgsArray
{
    /* Commandline args - shared with all out threads */
    string argScanPath; /// Path to directory to scan
    bool argRecursive; /// Scan recursively
    bool argScanFiles; /// Scan for new files
    string argJSONFile; /// PathName of JSON file to write
    bool argDoFileTypes; /// Use the 'file' utility to scan filetypes
    bool argDoChecksums; /// Calculate the checksums
    bool argDoMediaSig; /// Calculate the media signature
    bool argRescanMediaSig; /// Rescan all files for media signature, even if already present
    bool argScanArchives; /// Scan the contents of archives
    bool argScanTorrents; /// Scan the contents of torrent files
    bool argRunAnalysis; /// Execute analysis on database
    bool argDropMissing; /// Drop missing files from database
    bool argWriteJSON; /// Write file to disk, maybe -f is needed
    int argNumberOfThreads = 1; /// Number of worker threads for pool
    bool argForceOverwrite; /// ForceOverwrite of defective/alien JSON files
    bool argPickHidden; /// Pick hidden files and directories too
    bool argVerboseOutputs; /// be verbose
}
/** This is the global args array */
ArgsArray argsArray;

/** Parse command-line arguments into an ArgsArray instance.
 *
 * Params:
 *   args = raw command-line arguments
 *   argsarray = destination struct for parsed values
 * Returns:
 *   true, if parsing and validation were successful
 */
bool parseCommandLineArgs(string[] args, ArgsArray* argsarray = &argsArray)
{
    if (args.length <= 1)
        args ~= "--help"; // Show help, if no args given.

    /* Parse the commandline with std.getopt */
    auto helpInformation = getopt(args, /* std.getopt.config.required, */
        "path|p", "Path to scan for files", &argsarray.argScanPath,
        "json|j", "Name of JSON file to read from and store results to", &argsarray.argJSONFile,
        "recursive|r", "Recursively scan directories", &argsarray.argRecursive,
        "scan|s", "Scan for new files.", &argsarray.argScanFiles,
        "checksum|c", "Calculate the checksums", &argsarray.argDoChecksums,
        "filetypes|y", "Query file type with 'file' utility", &argsarray.argDoFileTypes,
        "mediasig|m", "Calculate the media signature", &argsarray.argDoMediaSig,
        "rescan-mediasig", "Rescan all files for media signature", &argsarray.argRescanMediaSig,
        "scanArchives|z", "Get the contents of archives", &argsarray.argScanArchives,
        "scanTorrents|o", "Get the contents of torrent files", &argsarray.argScanTorrents,
        "analyse|a", "Analyze database", &argsarray.argRunAnalysis,
        "dropMissing|d", "Drop missing files from database", &argsarray.argDropMissing,
        "writeJSON|w", "Write the modified JSON data.", &argsarray.argWriteJSON,
        "threads|t", "Number of worker threads", &argsarray.argNumberOfThreads,
        "force|f", "Force overwriting JSON file", &argsarray.argForceOverwrite,
        "pickhidden|h", "Pick hidden files and directories too", &argsarray.argPickHidden,
        "verbose|v", "Be verbose", &argsarray.argVerboseOutputs);

    if (helpInformation.helpWanted)
    {
        log(helpText);
        version (unittest)
        {
        }
        else
        {
            defaultGetoptPrinter("A file scanner and metadata scraper", helpInformation.options);
        }
        return false;
    }
    /* Validate some arguments */
    if (argsarray.argScanPath.empty)
    {
        logLine("We need a scan path. Use -p to specify it.");
        return false;
    }
    /* Test, that we got a directory path passed in */
    if (!exists(argsarray.argScanPath))
    {
        logFLine("We need a directory for the scan path. '%s' doesn't even exist.",
            argsarray.argScanPath);
        return false;
    }
    if (!isDir(argsarray.argScanPath))
    {
        logFLine("We need a directory for the scan path. '%s' is not a directory.",
            argsarray.argScanPath);
        return false;
    }

    if (argsarray.argJSONFile.empty ||
         // !argsarray.argJSONFile.isValidFilename ||
        !argsarray.argJSONFile.endsWith(jsonFileExtension))
    {
        logFLine("JSON filename '%s' looks invalid.", argsarray.argJSONFile);
        logLine("We expect a filename here, not a path.");
        logLine("We expect the \"" ~ jsonFileExtension ~ "\" file extension.");
        return false;
    }

    /* Check for existing JSON file */
    if (argsarray.argJSONFile.exists)
    {
        logLine("JSON file '", argsarray.argJSONFile, "' exists.");
        if (argsarray.argWriteJSON)
        {
            if (argsarray.argForceOverwrite)
            {
                logLine("Force overwriting of existing JSON file.");
            }
            else
            {
                logLine("Abort program. Use -f to force overwriting of output file.");
                return false;
            }
        }
    }

    return true;
}

@("parseCommandLineArgs")
unittest
{
    enum testdir = "./test/";
    enum jsonfile = "./test/json_file_v2.json";
    enum nojsonfile = "./test/json_file_test.json";
    ArgsArray args;

    string[] testArgs0 = ["programname"];
    bool res0 = parseCommandLineArgs(testArgs0, &args);
    assert(res0 == false, "Should be false. No args given.");

    string[] testArgs1 = ["programname", "-v"];
    bool res1 = parseCommandLineArgs(testArgs1, &args);
    assert(res1 == false, "Should be false. No scan path given.");
    string[] testArgs1a = ["programname", "-p", "./noexist"];
    bool res1a = parseCommandLineArgs(testArgs1a, &args);
    assert(res1a == false, "Should be false. No scan path given.");
    string[] testArgs1b = ["programname", "-p", testdir];
    bool res1b = parseCommandLineArgs(testArgs1b, &args);
    assert(res1b == false, "Should be false. No scanpath given.");
    string[] testArgs1c = ["programname", "-p", jsonfile];
    bool res1c = parseCommandLineArgs(testArgs1c, &args);
    assert(res1c == false, "Should be false. No jsonfile given.");

    string[] testArgs2 = ["programname", "-p", testdir, "-j", jsonfile, "-w"];
    bool res2 = parseCommandLineArgs(testArgs2, &args);
    assert(res2 == false, "Should be false. No overwrite for jsonfile given.");
    string[] testArgs2a = ["programname", "-p", testdir, "-j", nojsonfile];
    bool res2a = parseCommandLineArgs(testArgs2a, &args);
    assert(res2a == true, "Should be true. No jsonfile exists.");
    string[] testArgs2b = ["programname", "-p", testdir, "-j", jsonfile, "-f"];
    bool res2b = parseCommandLineArgs(testArgs2b, &args);
    assert(res2b == true, "Should be true. Overwrite for jsonfile given.");
    string[] testArgs2c = ["programname", "-p", testdir, "-j", jsonfile, "-w", "-f"];
    bool res2c = parseCommandLineArgs(testArgs2c, &args);
    assert(res2c == true, "Should be true. Overwrite for jsonfile given.");

    /* All args set */
    string[] testArgs = [
        "programname", "-p", testdir, "-j", jsonfile, "-r", "-s",
        "-c", "-y", "-m", "-a", "-w", "-t", "4", "-f", "-h", "-v"
    ];
    bool res = parseCommandLineArgs(testArgs, &args);
    assert(res == true, "Parsing failed");
    assert(args.argScanPath == testdir, args.argScanPath);
    assert(args.argJSONFile == jsonfile, args.argJSONFile);
    assert(args.argRecursive == true, args.argRecursive.to!string);
    assert(args.argScanFiles == true, args.argScanFiles.to!string);
    assert(args.argDoChecksums == true, args.argDoChecksums.to!string);
    assert(args.argDoFileTypes == true, args.argDoFileTypes.to!string);
    assert(args.argDoMediaSig == true, args.argDoMediaSig.to!string);
    assert(args.argRunAnalysis == true, args.argRunAnalysis.to!string);
    assert(args.argWriteJSON == true, args.argWriteJSON.to!string);
    assert(args.argNumberOfThreads == 4, args.argNumberOfThreads.to!string);
    assert(args.argForceOverwrite == true, args.argForceOverwrite.to!string);
    assert(args.argPickHidden == true, args.argPickHidden.to!string);
    assert(args.argVerboseOutputs == true, args.argVerboseOutputs.to!string);
}

/** Shortens a string `s` to exactly `maxLen` characters.
 * If `s` is longer, the middle part is replaced by "..."
 * so the resulting string has exactly `maxLen` characters.
 */
dstring shortenMiddle(string str, size_t maxLen)
{
    import std.utf : validate;

    enum ellipsis = "..."d;
    enum ellipsisLen = ellipsis.length;

    assertNotThrown(str.validate, str);

    // Convert to dstring to have simple and safe unicode operations.
    dstring dstr = str.to!dstring;

    // Simple cases
    if (dstr.length <= maxLen || maxLen == 0)
        return dstr;
    // If maxLen is too small to reasonably include "...",
    // just return the first maxLen characters.
    if (maxLen <= ellipsisLen)
        return dstr[0 .. maxLen];

    // Remaining characters available for prefix + suffix
    auto remain = maxLen - ellipsisLen;

    // Split between start and end parts
    auto headLen = remain / 2 + (remain % 2); // odd -> one extra in the front
    auto tailLen = remain - headLen;

    auto head = dstr[0 .. headLen];
    auto tail = dstr[$ - tailLen .. $];

    auto result = (head ~ ellipsis ~ tail);

    return result;
}

@("shortenMiddle")
unittest
{
    auto type0 = shortenMiddle("123456", 3);
    assert(type0 == "123"d, type0.to!string);

    auto str1 = "test/dummy-text-file.txt";
    auto type1 = shortenMiddle(str1, 60);
    assert(type1 == str1.to!dstring, type1.to!string);
    assert(type1.length == str1.length, type1.to!string);

    auto str2 = "test/test2/test3/test4/very-long-dummy-very-long-audio-file.mp3";
    auto type2 = shortenMiddle(str2, 60);
    auto str2a = "test/test2/test3/test4/very-l...mmy-very-long-audio-file.mp3"d;
    assert(type2 == str2a, type2.to!string);
    assert(type2.length == 60, type2.to!string);

    auto type3 = shortenMiddle(`さいごの果実 / ミツバチと科学者`, 10);
    assert(type3 == "さいごの...科学者"d, type3.to!string);
    assert(type3.length == 10, type3.to!string);

    auto type4 = shortenMiddle("|aaaa|bbbb|cccc|dddd|eeee|ffff|gggg|hhhh", 15);
    assert(type4.length == 15, type4.to!string);
    assert(type4 == "|aaaa|...g|hhhh", type4.to!string);
}

/** Pad whitespace to the left side of a string.
 *
 * Params:
 *   s = input string
 *   padlen = target length after left-padding
 * Returns:
 *   padded string, or the original string if it is already longer than `padlen`
 */
dstring padLeft(dstring s, size_t padlen)
{
    size_t slen = s.length;
    if (slen > padlen)
        return s;

    size_t plen = padlen - slen;
    auto pad = " ".cycle.take(plen).array.to!dstring;

    // auto rv = s ~ pad;
    auto rv = pad ~ s;
    return rv;
}

unittest
{
    dstring a = "!--- !--- !--- ";
    dstring a1 = padLeft(a, 10);
    assert(a == a1, a1.to!string);

    dstring a2 = padLeft(a, 15);
    assert(a == a2, a2.to!string);

    dstring a3 = padLeft(a, 20);
    dstring b3 = "     !--- !--- !--- "d;
    assert(b3 == a3, a3.to!string);

}

/** Wrapper around a progress callback function pointer. */
struct ProgressCallBack
{
    void function(size_t i, size_t m) fp;
}

/** Create a spinner character plus normalized progress text.
 *
 * Params:
 *   i = current value
 *   m = maximum value
 * Returns:
 *   progress string in the form `<spinner> <ratio>`
 */
string makeProgressString(size_t i, size_t m)
{
    import logging;
    import std.range;

    static int q = 0;
    char[] p = ['-', '\\', '|', '/', '-', '|', '/', '-'];
    auto result = format("%c %.6f", p[q++], (i.to!float / m.to!float));
    q &= 0x7;
    return result;
}

@("makeProgressString")
unittest
{
    auto s1 = makeProgressString(0, 100);
    assert(s1.startsWith("- 0.000000"), s1);
    auto s2 = makeProgressString(50, 100);
    assert(s2.startsWith("\\ 0.500000"), s2);
    auto s3 = makeProgressString(100, 100);
    assert(s3.startsWith("| 1.000000"), s3);
}

/** Update progress output for a sub-task callback.
 *
 * Params:
 *   i = current value
 *   m = maximum value
 */
void progressCallBack(size_t i, size_t m)
{
    //log(makeProgressString(i, m));
    printProgress(lastIdx, lastTotalFiles, lastFile, makeProgressString(i, m));
}

import std.datetime;

SysTime lastProgress;
size_t lastIdx;
size_t lastTotalFiles;
string lastFile;

/** Print scan progress on a single console line.
 *
 * Params:
 *   idx = current position
 *   totalfiles = max position
 *   file = file we operate on or null
 *   subJob = optional subjob description
 */
void printProgress(size_t idx, size_t totalfiles, string file, string subJob = null)
{
    enum EL0 = "\x1b[K"; // Delete to end of line, to clear the line after the progress output

    lastIdx = idx;
    lastTotalFiles = totalfiles;
    lastFile = file;

    if (file.empty || idx == 0)
    {
        lastProgress = Clock.currTime;
    }
    Duration lastDelta = Clock.currTime - lastProgress;
    bool itsTime = lastDelta > dur!"seconds"(1);
    if (file.empty || idx == 0 || itsTime)
    {
        enum fnfsz = 66;
        auto fileEclipsed = shortenMiddle(file, fnfsz);
        assert(fileEclipsed.length <= fnfsz, "clip: " ~ fileEclipsed.length.text);
        fileEclipsed = padLeft(fileEclipsed, fnfsz);
        try
        {
            logF("\r%6d/%6d:%10s:%s" ~ EL0, idx, totalfiles, subJob, fileEclipsed[$ - fnfsz .. $]);
        }
        catch (Exception ex)
        {
            logLine("\n");
            logFLine("Catched exception: %s\nFile: %s", ex.msg, file);
            //assert(false, ex.msg);
        }
        lastProgress = Clock.currTime;
    }
    else
    {
        //writeln("Boooh");
    }
}

@("printProgress")
unittest
{
    printProgress(0, 1000, "test/dummy-text-file.txt");
    printProgress(1, 1000, "test/dummy-text-file.txt");
    printProgress(10, 1000, "test/dummy-text-file.txt");
    printProgress(100, 1000, "test/dummy-text-file.txt");
    printProgress(1000, 1000, "test/dummy-text-file.txt");
    logLine("");
}
