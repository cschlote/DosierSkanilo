/** File type signature helper using the Linux `file` utility.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.fileutilsig;

import logging;
import std.algorithm.searching;

/** Query the file type string for a file path.
 *
 * Params:
 *   filename = file to inspect
 * Returns:
 *   file type string, or null when the type cannot be determined.
 */
string getFileType(const string filename)
{
    import std.process : execute, executeShell;
    import std.string : strip;
    import std.file : exists;

    if (!exists(filename))
    {
        logFLineVerbose("\nFile '%s' does not exist", filename);
        return null;
    }
    auto rc = execute(["file", "-b", filename]);
    // assert(rc.status == 0, rc.output);
    if (rc.status)
    {
        logFLine("\n'file' utility failed with rc %d on file '%s'", rc.status, filename);
        return null;
    }
    // writeln(rc.output);
    auto rv = rc.output.strip;
    // if (rv == "data")
    //     rv = null;
    return rv;
}

@("getFileType")
unittest
{
    import std.stdio : writeln;

    auto type1 = getFileType("test/dummy-text-file.txt");

    assert(type1 == "ASCII text", type1);

    auto type2 = getFileType("test/dummy-audio-file.mp3");
    // writeln(type2);
    assert(type2.startsWith(
            "Audio file with ID3 version 2.3.0, contains: MPEG ADTS, layer III, v1, 128 kbps, 44.1 kHz, JntStereo"), type2);

    auto type3 = getFileType("test/no-file.txt");
    assert(type3 is null, type3);
}
