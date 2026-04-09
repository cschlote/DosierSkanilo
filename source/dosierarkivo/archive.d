/** Archive abstraction and extraction helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.archive;

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
