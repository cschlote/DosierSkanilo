/** Shared unittest helpers for archive implementations.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.testsupport;

version (unittest)
{
    import std.conv : to;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID, thisThreadID;

    import dosierarkivo.archive;

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
        "test/json_file_v2_archive.json", "test/json_file_v2_torrent.json",
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
        assert(list.length == expectedEntries.length, list.to!string);

        foreach (listEntry; list)
        {
            auto destFile = buildPath(getTmpDirPrefix, listEntry);
            auto rv = obj.extractEntry(listEntry, getTmpDirPrefix);
            assert(rv);
            auto expectedFile = buildPath(destFile);
            assert(expectedFile.exists, expectedFile);

            import dosierskanilo.metadata.digests : calculatesDigests;

            ubyte[] sha1sum_s, sha1sum_d;
            calculatesDigests(null, listEntry, null, &sha1sum_s, null, null);
            calculatesDigests(null, expectedFile, null, &sha1sum_d, null, null);
            assert(sha1sum_s == sha1sum_d);
        }
    }
}
