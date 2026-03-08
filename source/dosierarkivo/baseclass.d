/** Archive abstraction and extraction helpers.
 *
 * This code might be useful for other projects. Instead of replicating code we either
 * use an existing library or we put the code here and make it available to other projects. This module
 * contains the baseclass for file archives and the factory method to create an instance.
 */
module dosierarkivo.baseclass;

import std.algorithm;
import std.conv;
import std.string;
import std.file;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import core.sys.posix.libgen;
import dosierskanilo.namedbinaryblob;

/** Types of archives we support */
enum ArchiveType
{
    unknown,
    zip,
    tar,
    rar,
    _7z
}

enum ZIP_SUFFIX = ".zip";
enum TAR_SUFFIX = ".tar";
enum RAR_SUFFIX = ".rar";
enum _7Z_SUFFIX = ".7z";

/** Factory that creates a FileArchive object for a supported archive type.
 *
 * Params:
 *   filename = archive file path
 * Returns:
 *   FileArchive instance, or null if the file is missing or unsupported.
 */
FileArchive fileArchive(string filename)
{
    if (filename.exists == false)
        return null;

    FileArchive fa;
    switch (filename.toLower.extension)
    {
    case ZIP_SUFFIX:
        fa = new FileArchiveZip(filename);
        break;
    case TAR_SUFFIX:
        fa = new FileArchiveTar(filename);
        break;
    case RAR_SUFFIX:
        fa = new FileArchiveRar(filename);
        break;
    case _7Z_SUFFIX:
        fa = new FileArchive7z(filename);
        break;
    default:
        fa = null;
        break;
    }
    return fa;
}

@("fileArchive() edgecase")
unittest
{
    auto fa = fileArchive("test/not-found.txt");
    assert(fa is null);
}

/* -------------------------------------------------------------------- */

/** Top-level representation of an archive file.
 *
 * The idea is to have a baseclass with the common interface and then have implementations
 * for the different archive types. The baseclass can be used in the rest of the code and
 * the factory method creates an instance of the correct type. When we need to support a new
 * archive type, we just add a new implementation and extend the factory method.
 */
abstract class FileArchive
{
    const ArchiveType fileType;
    string fileName; /// path to archive file

    this(ArchiveType type, string filename)
    {
        fileType = type;
        fileName = filename;
    }

    /** Get list of entries in archive
     * Returns:
     *   null or list of entries in archive
     */
    string[] getEntries()
    {
        return null;
    }

    /** Extract entry from archive to destination directory. The destination file is the same as the entry name.
     *
     * Params:
     *   filename = name of entry in archive
     *   destDir = directory to extract to
     * Returns:
     *   true on success, false on failure
     */
    bool extractEntry(string filename, string destDir)
    {
        return false;
    }

    /* -------------------------------------------------------------------- */
    version (unittest)
    {
        static void createTestArchive()
        {
        }

        static void deleteTestArchive()
        {
        }
    }
}

/* Unit tests for the baseclass are in the unittest of the implementations, because we need to test the factory
   method and the common interface. The actual tests are in a separate function, which is called from the unittests
   of the implementations. This way we avoid code duplication and we test the common interface in all implementations.
*/
version (unittest)
{
    string getTmpDirPrefix()
    {
        return buildPath(
            tempDir, "dosierskanilo-" ~ thisProcessID.to!string ~ "-" ~ thisThreadID.to!string);
    }

    enum zipFileName = "test.zip";
    enum tarFileName = "test.tar";
    enum rarFileName = "test.rar";
    enum _7zFileName = "test.7z";

    string[] expectedEntries = [
        "test/dummy-audio-file.mp3", "test/dummy-picture-file.jpg",
        "test/dummy-subtitle-file-copy.srt", "test/dummy-subtitle-file.srt",
        "test/dummy-text-file.txt", "test/dummy-video-file.mp4.mkv",
        "test/example.torrent", "test/json_file_v0.json", "test/json_file_v1.json",
        "test/json_file_v1_wrongversion.json", "test/json_file_v2.json",
        "test/test-multifile.torrent"
    ];

    /** Extract files from archive and compare with expected files. The expected files are in the test directory
     * and have the same name as the entries in the archive. The files are extracted to a temporary directory and
     * then compared with the expected files. The temporary directory is deleted after the test.
     *
     * Params:
     *   obj = FileArchive object to test
     */
    void testAbstractImpl(FileArchive obj)
    {
        mkdirRecurse(getTmpDirPrefix);
        scope (success)
            if (getTmpDirPrefix.exists)
                rmdirRecurse(getTmpDirPrefix);

        auto list = obj.getEntries();
        assert(list !is null);
        // writeln(list);
        assert(list.length == expectedEntries.length, list.to!string);

        foreach (listEntry; list)
        {
            // writeln(listEntry);
            auto destFile = buildPath(getTmpDirPrefix, listEntry);
            auto rv = obj.extractEntry(listEntry, getTmpDirPrefix);
            assert(rv);
            auto expectedFile = buildPath(destFile);
            assert(expectedFile.exists, expectedFile);

            import dosierskanilo.digests;

            ubyte[] sha1sum_s, sha1sum_d;
            calculatesDigests(null, listEntry, null, &sha1sum_s, null, null);
            calculatesDigests(null, expectedFile, null, &sha1sum_d, null, null);
            assert(sha1sum_s == sha1sum_d);
        }
    }
}

/* -------------------------------------------------------------------- */

/** Implementation for zip files.
 *
 * We use the unzip utility to get the list of entries and to extract files. The unzip utility is available
 * on most systems and supports a wide range of zip formats. The output of the unzip utility is parsed to
 * get the list of entries and to extract files.
 */
class FileArchiveZip : FileArchive
{
    private string[] parseUnzipLongListOutput(string output) const
    {
        string[] entries;
        bool inEntrySection = false;

        foreach (line; output.splitLines)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;

            if (!inEntrySection)
            {
                if (trimmed.startsWith("---------"))
                    inEntrySection = true;
                continue;
            }

            if (trimmed.startsWith("---------"))
                break; // Summary line after entry block.

            auto m = matchFirst(line, `^\s*\d+\s+\S+\s+\S+\s+(.+?)\s*$`);
            if (m.empty)
                continue;

            auto entryName = m.captures[1].strip;
            if (!entryName.empty)
                entries ~= entryName;
        }

        return entries;
    }

    this(string filename)
    {
        super(ArchiveType.zip, filename);
    }

    override string[] getEntries()
    {
        auto rcMachineReadable = execute(["unzip", "-Z1", this.fileName]);
        if (rcMachineReadable.status == 0)
        {
            return rcMachineReadable.output
                .splitLines
                .map!(line => line.strip)
                .filter!(line => !line.empty)
                .array;
        }

        stderr.writeln("WARNING: unzip -Z1 failed for '", this.fileName,
            "'. Falling back to parsing unzip -l output.");

        auto rcLongList = execute(["unzip", "-l", this.fileName]);
        if (rcLongList.status != 0)
        {
            stderr.writeln("WARNING: unzip -l failed for '", this.fileName,
                "'. Skipping archive entry scan.");
            return [];
        }

        auto entries = parseUnzipLongListOutput(rcLongList.output);
        if (entries.empty)
        {
            stderr.writeln("WARNING: Could not parse unzip -l output for '", this.fileName,
                "'. Skipping archive entry scan.");
        }
        return entries;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto zipPath = buildPath(getcwd, this.fileName);
        auto rc = execute(["unzip", "-d", destDir, zipPath, filename]);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = zipFileName;
        static void createTestArchive()
        {
            if (fn.exists)
                std.file.remove(fn);
            auto rc = executeShell("zip -q \"%s\" test/*".format(zipFileName));
            write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                std.file.remove(fn);
        }
    }
}

@("class FileArchiveZip")
unittest
{
    FileArchiveZip.createTestArchive;
    scope (exit)
        FileArchiveZip.deleteTestArchive;

    // auto obj = new FileArchiveZip(zipFileName);
    auto obj = fileArchive(zipFileName);

    // auto list = obj.getEntries();
    testAbstractImpl(obj);
}

@("zip list parser tolerates output drift")
unittest
{
    auto obj = new FileArchiveZip("dummy.zip");
    auto parsed = obj.parseUnzipLongListOutput("unexpected output\nwithout expected columns\n");
    assert(parsed.length == 0);
}

/* -------------------------------------------------------------------- */

class FileArchiveTar : FileArchive
{
    this(string filename)
    {
        super(ArchiveType.tar, filename);
    }

    override string[] getEntries()
    {
        auto rc = execute(["tar", "-tf", this.fileName]);
        // write(rc.output);
        assert(rc.status == 0, rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto rc = execute(["tar", "-xf", tarPath, "-C", destDir, filename]);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = tarFileName;
        static void createTestArchive()
        {
            deleteTestArchive;
            auto rc = executeShell("tar -cf \"%s\" test/*".format(tarFileName));
            write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                std.file.remove(fn);
        }
    }
}

@("class FileArchiveTar")
unittest
{
    FileArchiveTar.createTestArchive;
    scope (exit)
        FileArchiveTar.deleteTestArchive;

    // auto obj = new FileArchiveTar(tarFileName);
    auto obj = fileArchive(tarFileName);

    // auto list = obj.getEntries();
    testAbstractImpl(obj);
}

/* -------------------------------------------------------------------- */

class FileArchiveRar : FileArchive
{
    this(string filename)
    {
        super(ArchiveType.rar, filename);
    }

    override string[] getEntries()
    {
        auto rc = execute(["unrar", "lb", this.fileName]);
        assert(rc.status == 0, rc.output);
        auto res = rc.output.split("\n").filter!(a => !a.empty).array;
        return res;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto rc = execute(["unrar", "x", "-pX", tarPath, filename, destDir]);
        // write(rc.output);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = rarFileName;
        static void createTestArchive()
        {
            deleteTestArchive;
            auto cmd = "rar a \"%s\" test/*".format(rarFileName);
            auto rc = executeShell(cmd);
            // write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                std.file.remove(fn);
        }
    }
}

@("class FileArchiveRar")
unittest
{
    if (executeShell("command -v rar").status != 0)
        return; // Alpine CI does not provide proprietary `rar`.

    FileArchiveRar.createTestArchive;
    scope (exit)
        FileArchiveRar.deleteTestArchive;

    // auto obj = new FileArchiveTar(tarFileName);
    auto obj = fileArchive(rarFileName);

    // auto list = obj.getEntries();
    testAbstractImpl(obj);
}

/* -------------------------------------------------------------------- */

class FileArchive7z : FileArchive
{
    this(string filename)
    {
        super(ArchiveType._7z, filename);
    }

    override string[] getEntries()
    {
        auto rc0 = execute(["7z", "l", "-p", "-ba", this.fileName]);
        if (rc0.status == 2)
        {
            write(rc0.output);
            return null; // Archive is password protected, we cannot get the list of entries.
        }

        auto rc = execute(["7z", "l", "-ba", this.fileName]);
        assert(rc.status == 0, rc.output);

        string[] entries;
        auto lines = rc.output.splitLines;
        foreach (line; lines)
        {
            auto m = matchFirst(line,
                `^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\d+)\s+(\d*)\s+(.+)$`);
            if (m.empty)
                continue;

            auto attrs = m.captures[3];
            if (attrs.length > 0 && attrs[0] == 'D')
                continue;

            auto entryName = m.captures[6].strip;
            if (!entryName.empty)
                entries ~= entryName;
        }
        return entries;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto rc = execute(["7z", "x", tarPath, filename, "-o" ~ destDir]);
        // write(rc.output);
        assert(rc.status == 0, rc.output);
        return true;
    }

    version (unittest)
    {
        enum string fn = _7zFileName;
        static void createTestArchive()
        {
            deleteTestArchive;
            auto cmd = "7z a \"%s\" test/*".format(_7zFileName);
            auto rc = executeShell(cmd);
            // write(rc.output);
            assert(rc.status == 0, rc.output);
        }

        static void deleteTestArchive()
        {
            if (fn.exists)
                std.file.remove(fn);
        }
    }
}

@("class FileArchive7z")
unittest
{
    FileArchive7z.createTestArchive;
    scope (exit)
        FileArchive7z.deleteTestArchive;

    // auto obj = new FileArchiveTar(tarFileName);
    auto obj = fileArchive(_7zFileName);

    // auto list = obj.getEntries();
    testAbstractImpl(obj);
}

@("archive extraction with special filenames")
unittest
{
    auto tmpRoot = buildPath(tempDir, "dosierskanilo-archive-safe-" ~ thisProcessID.to!string);
    if (tmpRoot.exists)
        rmdirRecurse(tmpRoot);
    mkdirRecurse(tmpRoot);
    scope (exit)
        if (tmpRoot.exists)
            rmdirRecurse(tmpRoot);

    auto specialEntryName = "special 'quoted' ;$ file.txt";
    auto specialSourceFile = buildPath(tmpRoot, specialEntryName);
    std.file.write(specialSourceFile, "archive safety regression test\n");

    auto zipArchiveName = "special ;$ 'archive'.zip";
    auto zipArchivePath = buildPath(tmpRoot, zipArchiveName);
    auto zipCreate = execute(["zip", "-q", "-j", zipArchivePath, specialSourceFile]);
    assert(zipCreate.status == 0, zipCreate.output);

    auto zipObj = fileArchive(zipArchivePath);
    assert(zipObj !is null);
    auto zipEntries = zipObj.getEntries();
    assert(zipEntries.countUntil(specialEntryName) >= 0, zipEntries.to!string);

    auto zipExtractDir = buildPath(tmpRoot, "extract zip ;$ dir");
    mkdirRecurse(zipExtractDir);
    assert(zipObj.extractEntry(specialEntryName, zipExtractDir));
    assert(buildPath(zipExtractDir, specialEntryName).exists);

    auto tarArchiveName = "special ;$ 'archive'.tar";
    auto tarArchivePath = buildPath(tmpRoot, tarArchiveName);
    auto tarCreate = execute(["tar", "-cf", tarArchivePath, "-C", tmpRoot, specialEntryName]);
    assert(tarCreate.status == 0, tarCreate.output);

    auto tarObj = fileArchive(tarArchivePath);
    assert(tarObj !is null);
    auto tarEntries = tarObj.getEntries();
    assert(tarEntries.countUntil(specialEntryName) >= 0, tarEntries.to!string);

    auto tarExtractDir = buildPath(tmpRoot, "extract tar ;$ dir");
    mkdirRecurse(tarExtractDir);
    assert(tarObj.extractEntry(specialEntryName, tarExtractDir));
    assert(buildPath(tarExtractDir, specialEntryName).exists);
}
