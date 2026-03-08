/** A tool to extract files from archives.
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

/** Factory to produce an FileArchiver object of correct type or null, when not supported or file not found.
 *
 * Params:
 *   filename = Name of Archiv.
 * Returns:
 *   null or a FileArchive baseclass
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

/** TopLevel representation of an FileArchive
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
    this(string filename)
    {
        super(ArchiveType.zip, filename);
    }

    override string[] getEntries()
    {
        auto rc = executeShell("unzip -l %s".format(this.fileName));
        assert(rc.status == 0, rc.output);
        // writeln(rc.output);
        auto res = rc.output.split("\n").filter!(a => !a.empty).array;
        // writeln(res);

        enum prefixLen = 3;
        enum postfixLen = 2;
        assert(res.length >= (prefixLen + postfixLen)); // 3 Lines at start and 2 lines at end are dropped.
        auto res2 = res[prefixLen .. $ - postfixLen];

        enum header = "---------  ---------- -----   ----";
        enum headerLen = header.length;
        assert(res[2] == header, "Zip output changed?\n" ~ res[2]);
        enum headerSkipTail = "----".length;
        enum skipLen = headerLen - headerSkipTail;
        auto res3 = res2.map!(a => a[skipLen .. $])();
        // writeln(res3);
        return res3.array;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto zipPath = buildPath(getcwd, this.fileName);
        auto cmd = "cd %s && unzip \"%s\" \"%s\"".format(destDir, zipPath, filename);
        // writeln(cmd);
        auto rc = executeShell(cmd);
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

/* -------------------------------------------------------------------- */

class FileArchiveTar : FileArchive
{
    this(string filename)
    {
        super(ArchiveType.tar, filename);
    }

    override string[] getEntries()
    {
        auto rc = executeShell("tar -tf \"%s\"".format(this.fileName));
        // write(rc.output);
        assert(rc.status == 0, rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto cmd = "tar -xf \"%s\" -C\"%s\" \"%s\"".format(tarPath, destDir, filename);
        // writeln(cmd);
        auto rc = executeShell(cmd);
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
        auto rc = executeShell("unrar lb \"%s\"".format(this.fileName));
        assert(rc.status == 0, rc.output);
        auto res = rc.output.split("\n").filter!(a => !a.empty).array;
        return res;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto cmd = "cd %s && unrar x -pX \"%s\" \"%s\"".format(destDir, tarPath, filename);
        // writeln(cmd);
        auto rc = executeShell(cmd);
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
        auto cmd0 = "7z l -p -ba \"%s\"".format(this.fileName);
        auto rc0 = executeShell(cmd0);
        if (rc0.status == 2)
        {
            write(rc0.output);
            return null; // Archive is password protected, we cannot get the list of entries.
        }

        auto cmd = "7z l -ba \"%s\" | grep -v ' D....' | awk '{print $NF}'".format(
            this.fileName);
        auto rc = executeShell(cmd);
        // write(rc.output);

        assert(rc.status == 0, rc.output);
        return rc.output.split("\n").filter!(a => !a.empty).array;
    }

    override bool extractEntry(string filename, string destDir)
    {
        auto tarPath = buildPath(getcwd, this.fileName);
        auto cmd = "cd %s && 7z x \"%s\" \"%s\"".format(destDir, tarPath, filename);
        // writeln(cmd);
        auto rc = executeShell(cmd);
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
