/** File type signature helper using the Linux `file` utility.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.metadata.fileutilsig;

import dosierskanilo.logging;
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

/** Query the installed `file` utility version string.
 *
 * Returns: version string reported by the `file` command, or `"unknown"` if
 * the version cannot be queried.
 */
string getFileUtilityVersion()
{
    import std.process : execute;
    import std.string : indexOf, strip;

    auto rc = execute(["file", "--version"]);
    if (rc.status != 0 || rc.output.strip.length == 0)
        return "unknown";

    auto versionText = rc.output.strip;
    auto newlineIndex = versionText.indexOf('\n');
    return (newlineIndex < 0 ? versionText : versionText[0 .. newlineIndex]).strip;
}

@("getFileType")
unittest
{
    import std.stdio : writeln;

    auto type1 = getFileType("test/dummy-text-file.txt");

    assert(type1 == "ASCII text", type1);

    auto type2 = getFileType("test/dummy-audio-file.mp3");
    // `file` changes its MP3 wording across versions, so keep the test stable
    // by checking for the relevant markers instead of the full sentence.
    assert(type2.canFind("Audio file with ID3 version 2.3.0"), type2);
    assert(type2.canFind("MPEG ADTS, layer III"), type2);

    auto type3 = getFileType("test/no-file.txt");
    assert(type3 is null, type3);
}

@("getFileUtilityVersion")
unittest
{
    auto versionText = getFileUtilityVersion();
    assert(versionText.length > 0, versionText);
}
