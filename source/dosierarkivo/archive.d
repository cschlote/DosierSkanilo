/** Archive abstraction and extraction helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierarkivo.archive;

/** Types of archives we support. */
enum ArchiveType
{
    unknown,
    zip,
    tar,
    rar,
    _7z
}

/** File extension for ZIP archives. */
enum ZIP_SUFFIX = ".zip";
/** File extension for TAR archives. */
enum TAR_SUFFIX = ".tar";
/** File extension for RAR archives. */
enum RAR_SUFFIX = ".rar";
/** File extension for 7z archives. */
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
    /** Archive type represented by the concrete implementation. */
    const ArchiveType fileType;
    /** Path to the archive file on disk. */
    string fileName;

    /** Create a new archive wrapper.
     *
     * Concrete implementations typically call this from their constructor to
     * initialize the shared fields.
     *
     * Params:
     *   type = archive type handled by the concrete implementation.
     *   filename = path to the archive file on disk.
     */
    this(ArchiveType type, string filename)
    {
        fileType = type;
        fileName = filename;
    }

    /** Get list of entries in archive
     *
     * The base implementation returns `null` and is meant to be overridden by
     * concrete archive handlers.
     *
     * Returns:
     *   `null` or the list of entries in the archive.
     */
    string[] getEntries()
    {
        return null;
    }

    /** Extract entry from archive to destination directory. The destination file is the same as the entry name.
     *
     * The base implementation returns `false` and is meant to be overridden by
     * concrete archive handlers.
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
