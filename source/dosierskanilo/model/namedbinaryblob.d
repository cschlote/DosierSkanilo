/** Data class for a unique binary blob with multiple names and MediaInfo
 *
 * All scanned information must be stored somewhere. The NamedBinaryBlob provides
 * a container object for this purpose, so each file and all its scanned properties
 * is represented by an object.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.namedbinaryblob;

import std.algorithm;
import std.array;
import std.datetime : Clock, dur;
import std.datetime.systime : SysTime;
import std.datetime.timezone : TimeZone;
import std.exception : assertThrown, enforce;
import std.string : startsWith;

import jsonizer;

import dosierarkivo;
import dosierarkivo.archive : appendArchiveVirtualPath,
    archivePathOccurrenceMarker, archivePathSeparator,
    escapeArchiveVirtualPath, nativePathToStoragePath,
    normalizeArchiveEntryPath, parseArchiveVirtualPath;
import dosierskanilo.archivebulk : ArchiveBulkMode, ArchiveBulkPlan,
    ArchiveBulkReservation, bulkExtractedMemberPath,
    maximumArchiveChunkBytes, maximumArchiveChunkMembers,
    minimumArchiveChunkBytes, planArchiveBulkExtraction, planArchiveChunk,
    sharedArchiveBulkStaging;
import dosierskanilo.catalogbackend : ArchiveEntryId, ContentId,
    ContentLocator, ReferenceId;
import dosierskanilo.logging;
import dosierskanilo.options;
import dosierskanilo.progress;
import dosierskanilo.membercontentcache : MemberContentCache,
    MemberContentCacheClosedException, MemberContentCacheException,
    MemberContentCancelledException, MemberContentLease,
    MemberContentNotExtractableException, sharedMemberContentCache;
import dosierskanilo.metadata.digests;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.fileutilsig : getFileUtilityVersion;
import dosierskanilo.metadata.torrentinfo;
public import dosierskanilo.model.archivespec;
public import dosierskanilo.model.checksums;
public import dosierskanilo.model.filespec;
public import dosierskanilo.model.blobarchives;
public import dosierskanilo.model.blobmerge;
public import dosierskanilo.model.blobupdates;
public import dosierskanilo.model.catalogjson;


/** Raised when a serialized catalog cannot be interpreted as a supported
 * version or shape.
 *
 * Callers may treat this as a recoverable malformed-input error, unlike I/O or
 * callback failures.
 */
class CatalogFormatException : Exception
{
	/** Build the exception with a diagnostic message.
	 *
	 * Params:
	 *     message = Human-readable description of the format failure.
	 */
	this(string message)
	{
		super(message);
	}
}

/** Raised when cooperative cancellation stops a deep archive scan.
 *
 * The blob carries the completed member specs and `archiveScanCursor` so the
 * caller can persist a resumable partial index instead of discarding work.
 */
class ArchiveScanCancelledException : Exception
{
	/** Build the exception with a diagnostic message.
	 *
	 * Params:
	 *     message = Human-readable cancellation reason.
	 */
	this(string message)
	{
		super(message);
	}
}

/** Whether a catalog read failure indicates malformed input.
 *
 * Such failures may be recovered by starting with an empty catalog when the
 * caller explicitly allows an overwrite. I/O, callback and out-of-memory
 * failures are not recoverable and must never be treated as "malformed".
 *
 * Params:
 *     error = Failure to classify; may be `null`.
 * Returns: `true` for this module's format exception, JSON parsing errors, or
 *     Jsonizer errors; `false` otherwise, including for `null`.
 */
bool isCatalogFormatFailure(Throwable error) @safe nothrow
{
	import std.json : JSONException;
	import jsonizer.exceptions : JsonizeException;

	if (error is null)
		return false;
	return cast(CatalogFormatException) error !is null
		|| cast(JSONException) error !is null
		|| cast(JsonizeException) error !is null;
}

enum int DATA_CLASS_VERSION1 = 1; ///< Current version of the NamedBinaryBlob structure, v1
enum int DATA_CLASS_VERSION2 = 2; ///< Current version of the NamedBinaryBlob structure, v2
enum int DATA_CLASS_VERSION3 = 3; ///< Legacy NamedBinaryBlob representation, v3
enum int DATA_CLASS_VERSION4 = 4; ///< Recursive archive-member representation, v4
enum int DATA_CLASS_VERSION5 = 5; ///< Current virtual-reference representation, v5

/** Helper task pointers used to run the per-blob update jobs in parallel. */
mixin template payloadHelpers()
{
	import std.parallelism : Task, task;

	Task!(updateDigests, NamedBinaryBlob, shared(bool)*, ProgressCallBack*)* task_hashme; ///< Pointer to hashing job
	Task!(updateFileType, NamedBinaryBlob)* task_filetype; /// Query filetype with 'file' utility
	Task!(updateMediaInfo, NamedBinaryBlob, bool)* task_mediasig; ///< Pointer to mediasig job
	Task!(updateArchives, NamedBinaryBlob, bool, bool, shared(bool)*, ProgressCallBack*,
		ArchivePasswordCallback, size_t, size_t, string, MemberContentCache, bool,
		bool, ArchiveBulkMode, ulong)* task_archiveScan; ///< Pointer to archive scan job
	Task!(updateTorrentInfo, NamedBinaryBlob)* task_torrentscan; ///< Pointer to torrent scan job
}

/** Wrapper class to serialize an array of NamedBinaryBlob objects
 *
 * This class wraps the data array together with global metadata that describes
 * the environment the data was collected with.
 */
struct NamedBinaryBlobCatalog
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize
	{
		ulong dataVersion; ///< version of the data structure
		NamedBinaryBlob[] dataArray; ///< Array of NamedBinaryBlob objects
	}

	@jsonize(Jsonize.opt)
	{
		string mediaInfoVersion; ///< version string of the MediaInfo library
		string fileUtilityVersion; ///< version string of the file utility
	}

	/** constructor with parameters
	 *
	 * Params:
	 *   dataversion = version of the data structure
	 *   dataarray = Array of NamedBinaryBlob objects
	 */
	@jsonize this(ulong dataversion, NamedBinaryBlob[] dataarray)
	{
		dataVersion = dataversion;
		dataArray = dataarray;
	}

	/** Refresh wrapper metadata from the current runtime environment. */
	void refreshRuntimeMetadata()
	{
		try
		{
			mediaInfoVersion = getMediaInfoVersion();
		}
		catch (Exception)
		{
			mediaInfoVersion = "unknown";
		}
		fileUtilityVersion = getFileUtilityVersion();
	}
}

@("struct NamedBinaryBlobCatalog")
unittest
{
	auto mis0 = new NamedBinaryBlob();
	auto mis1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567));
	auto mis3 = new NamedBinaryBlob([
		new FileSpec("file8", SysTime(1_234_567)),
		new FileSpec("file9", SysTime(2_234_567))
	], 1234);
	auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, [
		mis0, mis1, mis2, mis3
	]);
	assert(catalog.dataVersion == DATA_CLASS_VERSION3);
	assert(catalog.dataArray.length == 4);
	assert(catalog.mediaInfoVersion.length == 0);
	assert(catalog.fileUtilityVersion.length == 0);
	catalog.refreshRuntimeMetadata();
	assert(catalog.mediaInfoVersion.length > 0);
	assert(catalog.fileUtilityVersion.length > 0);
}

/** JSON domain record for binary content and its known file references.
 *
 * This JSON/Jsonizer type combines payload properties with `FileSpec[]`
 * filesystem references and optional metadata. It is the current interchange
 * representation. JSON v5 stores archive members as ordinary virtual
 * `FileSpec` references; older nested archive indexes are promoted when
 * writing. Checksum properties serialize as Base64 strings.
 */
class NamedBinaryBlob
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/** True when FileSpec names use the JSON-v5 archive virtual path grammar. */
	bool fileSpecsUseArchiveVirtualGrammar;
	/** True when the current archive scan continued a partial index. */
	bool archiveScanResumed;

	/* ------------------------------------------------------------------- */
	/* Some helper vars not serialized */
	// private:
	mixin payloadHelpers;

	@jsonize
	{
		size_t fileSize; ///< file size
	}

	/** Filename fields
	 *
	 * We support either a single filename (fileName) or multiple filenames
	 * (fileNames) for entries that represent multiple files (like multi-part
	 * archives or multi-track media files).
	 */
	@jsonize(Jsonize.opt)
	{
		CheckSums checkSums; ///< Multiple checksums of the file
		string fileName; ///< absolute filename  AND
		string timeLastModified; ///< Time of last modification OR
		FileSpec[] fileSpecs; /// v3: combined entry

		string fileType; /// Output of 'file' CLI tool.
		MediaInfoSig mediaInfoSig; ///< Parsed media info signature
		ArchiveSpec[] archiveSpecs; /// Contents of an archive
		bool archiveIndexKnown; /// JSON v5 archive-index state, including empty indexes
		bool archiveIndexDeep; /// True when member metadata was extracted deeply
		size_t archiveScanCursor; /// Next entry index for a partial deep scan
		string archivePassword; /// Optional password used to inspect this archive
		TorrentInfo torrentInfo; /// Extracted torrent information
	}

	// Legacy fields, kept for backward compatibility, but not serialized anymore
	// Data is dropped during serialization
	@jsonize(JsonizeIn.opt, JsonizeOut.no)
	{
		string[] fileNames; ///< set of absolute filenames and time (for multiple entries) OR
		string[] mediaInfo; ///< A media signature constructed with libmediainfo or NULL for no media file
		string md5sum_b64; ///< base64 of md5 hash
		string sha1sum_b64; ///< base 64 of sha1 hash
		string xxh64sum_b64; ///< base 64 of xxh64 hash
	}
	/* ------------------------------------------------------------------- */

	/* ------------------------------------------------------------------- */

	/** default constructor */
	this()
	{
		// Internal fields
		// invalidated = false;
		// isFileMissing = false;
		task_hashme = null;
		task_mediasig = null;

		// Unique binary blob parameters
		fileSpecs = [];
		fileSize = 0;
		checkSums = CheckSums();

		// Optional values with special usage
		fileNames = null; // OBSOLETE
		fileName = null; // Used to replace array by single string
		fileType = null; // Clear file util output
		timeLastModified = ""; // Used to replace array by single string
		mediaInfo = null; // More humand readable format
		mediaInfoSig = null; // MediaInfo as JSON fields
		archiveSpecs = null; // Contents of an archive
		archiveIndexKnown = false;
		archiveIndexDeep = false;
		archiveScanCursor = 0;
		archiveScanResumed = false;
		fileSpecsUseArchiveVirtualGrammar = false;
		archivePassword = ""; // Optional archive password
		torrentInfo = null; // Extracted torrent information
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   specs = array of FileSpec entries
	 *   size = file size
	 */
	this(FileSpec[] specs, size_t size)
	{
		this();
		fileSpecs ~= specs;
		fileSpecs.sort;
		fileSize = size;
	}
	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   name = absolute filename
	 *   size = file size
	 *   modificationTime = time of last modification
	 */
	this(string name, size_t size, SysTime modificationTime)
	{
		this();
		auto fileSpec = new FileSpec(name, modificationTime.toISOExtString);
		fileSpecs ~= fileSpec;
		fileSpecs.sort;
		fileSize = size;
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   names = absolute filenames
	 *   size = file size
	 *   modificationTime = time of last modification
	 */
	this(string[] names, size_t size, SysTime modificationTime)
	{
		this();
		foreach (fn; names)
			fileSpecs ~= new FileSpec(fn, modificationTime.toISOExtString);
		fileSpecs.sort;
		fileSize = size;
	}

	/** constructor with parameters for single file entry
	 *
	 * Params:
	 *   name = absolute filename
	 *   size = file size
	 *   modificationTime = time of last modification
	 *   sums = checksums
	 *   mt = media info or null
	 */
	this(string name, size_t size, SysTime modificationTime, CheckSums sums, MediaInfoSig mt = null)
	{
		this(name, size, modificationTime);
		checkSums = sums;
		mediaInfoSig = mt;
	}

	/** constructor with parameters for entry with several file entries
	 *
	 * Params:
	 *   names = absolute filenames
	 *   size = file size
	 *   modificationTime = time of last modification
	 *   sums = checksums
	 *   mt = media info or null
	 */
	this(string[] names, size_t size, SysTime modificationTime, CheckSums sums, MediaInfoSig mt = null)
	{
		this(names, size, modificationTime);
		//fileName = null;
		fileNames = names;
		fileSize = size;
		timeLastModified = modificationTime.toISOExtString();
		checkSums = sums;
		mediaInfoSig = mt;
	}

	/** copy constructor
	*
	* Params:
	*   other = Init object
	*/
	this(NamedBinaryBlob other)
	{
		this();
		fileSpecs = other.fileSpecs.dup;
		fileNames = other.fileNames.dup;
		fileSize = other.fileSize;
		timeLastModified = other.timeLastModified;
		checkSums = other.checkSums;
		fileType = other.fileType;
		mediaInfoSig = other.mediaInfoSig;
		torrentInfo = other.torrentInfo;
		archivePassword = other.archivePassword;
		archiveIndexKnown = other.archiveIndexKnown;
		archiveIndexDeep = other.archiveIndexDeep;
		archiveScanCursor = other.archiveScanCursor;
		archiveScanResumed = other.archiveScanResumed;
		fileSpecsUseArchiveVirtualGrammar = other.fileSpecsUseArchiveVirtualGrammar;
		if (other.archiveSpecs !is null)
		{
			archiveSpecs = [];
			foreach (entry; other.archiveSpecs)
				archiveSpecs ~= entry is null ? null : entry.dup();
		}
	}

	/* ------------------------------------------------------------------- */

	/** Create a string from the object contents.
	 *
	 * Returns: A diagnostic summary containing the base filename, size,
	 *     modification time, checksums, file type, and metadata.
	 */
	override string toString() const
	{
		import std.string : format;
		import std.path : baseName;

		//assert(fileNames.length > 0, "NamedBinaryBlob entry has no filenames!");
		auto filename = this.getFirstFileName;
		auto mtime = this.getFirstFileModDate;
		CheckSums sums = this.checkSums;

		return format("NamedBinaryBlob('%s', %d, %s, %s, fileType='%s', MI=%s, AR=%s, TO=%s)",
			baseName(filename), fileSize, mtime, sums, this.fileType, this.mediaInfoSig, this.archiveSpecs, this
				.torrentInfo);
	}

	/* ------------------------------------------------------------------- */

	/** equality operator
	 *
	 * We assume rquality, when size and checksums are equal. The filenames
	 * or media info are not relevant for equality. They are just metadata.
	 *
	 * We also check for full checksums. If not available, we can't match.
	 *
	 * Params:
	 *   other = other NamedBinaryBlob object to compare with
	 * Returns: true, if both objects are equal
	*/
	bool opEquals(const NamedBinaryBlob other) const @safe
	{
		if (other is null)
			return false;
		return this.fileSize == other.fileSize &&
			this.checkSums == other.checkSums;
	}

	/** hash function for the object
	 *
	 * We use the file size and checksums to calculate the hash. The filenames
	 * or media info are not relevant for hashing. They are just metadata.
	 *
	 * We also check for full checksums. If not available, we can't match.
	 *
	 * Returns: hash value for the object
	 */
	override size_t toHash() const nothrow @safe
	{
		size_t hash = this.fileSize;
		hash ^= this.checkSums.toHash + 0x9e3779b97f4a7c15UL + (hash << 6) + (hash >> 2);
		return hash;
	}

	/** Check if the blob is orphaned, i.e. if there is no file entry on disk for this blob
	 *
	 * Returns: true, if there is no file entry on disk for this blob, false otherwise
	 */
	bool isBlobOrphaned() ///< Set, when there is no file entry on disk for this blob
	{
		import std.algorithm : any;

		if (fileSpecsUseArchiveVirtualGrammar)
			return getExistingFiles().length == 0;
		bool rc = false;
		if (fileSpecs.length == 0)
			rc = true;
		else
		{
			rc = fileSpecs.all!(a => !(a.exists()));
		}
		return rc;
	}

	/** Create a deep copy of the object
	 *
	 * Returns: a new NamedBinaryBlob object with the same content as this object
	 */
	NamedBinaryBlob dup()
	{
		auto dc = new NamedBinaryBlob(this);
		if (dc.mediaInfoSig !is null)
			dc.mediaInfoSig = dc.mediaInfoSig.dup;
		if (dc.torrentInfo !is null)
			dc.torrentInfo = dc.torrentInfo.dup;
		return dc;
	}

	/* ------------------------------------------------------------------- */

	/** Get the first modification timestamp from sorted file entries.
	 *
	 * Returns: first file modification time, or "" for an empty set.
	 */
	string getFirstFileModDate() const
	{
		if (this.fileSpecs.length == 0)
			return "";

		size_t firstIndex = 0;
		foreach (index, fs; this.fileSpecs[1 .. $])
		{
			if (fs.timeLastModified < this.fileSpecs[firstIndex].timeLastModified)
				firstIndex = index + 1;
		}
		return this.fileSpecs[firstIndex].timeLastModified;
	}

	/** Get the first filename from sorted file entries.
	 *
	 * Returns: first filename, or "" for an empty set.
	 */
	string getFirstFileName() const
	{
		if (this.fileSpecs.length == 0)
			return "";

		size_t firstIndex = 0;
		foreach (index, fs; this.fileSpecs[1 .. $])
		{
			if (fs.fileName < this.fileSpecs[firstIndex].fileName)
				firstIndex = index + 1;
		}
		return this.fileSpecs[firstIndex].fileName;
	}

	/* ------------------------------------------------------------------- */

	/** Get all file entries that still exist on disk.
	 *
	 * Returns: existing `FileSpec` entries, or an empty array if none exist.
	 */
	FileSpec[] getExistingFiles() @safe
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		FileSpec[] rs = null;
		if (fileSpecs.length)
		{
			if (!fileSpecsUseArchiveVirtualGrammar)
				rs = fileSpecs.sort.filter!(a => a.exists).array;
			else
				foreach (spec; fileSpecs)
				{
					/* A virtual member exists as long as its container exists;
					 * its own path is not a file on disk. Keep the original spec
					 * so the escaped grammar is not lost. For non-virtual paths
					 * the parsed physical name is the openable disk name; the
					 * legacy scanner re-escapes it when writing specs back. */
					ParsedArchiveVirtualPath parsed;
					try
						parsed = parseArchiveVirtualPath(spec.fileName);
					catch (Exception)
						continue;
					if (parsed.physicalPath.length == 0
						|| !exists(parsed.physicalPath))
						continue;
					rs ~= parsed.isVirtual
						? spec
						: new FileSpec(parsed.physicalPath, spec.timeLastModified);
				}
			if (rs.length > 1)
				rs.sort;
		}
		return rs;
	}

	/** Return the openable physical path for a file spec.
	 *
	 * Params:
	 *     spec = File spec to inspect; may be `null`.
	 * Returns: The physical path for non-virtual specs, or an empty string for
	 *     virtual archive members, missing specs, or unparsable names.
	 */
	package(dosierskanilo) string physicalPathForSpec(FileSpec spec) const @safe
	{
		if (spec is null || spec.fileName.length == 0)
			return "";
		/* Legacy v3 names may contain literal `!` characters and are not
		 * written in the archive virtual grammar. */
		if (!fileSpecsUseArchiveVirtualGrammar)
			return spec.fileName;
		try
		{
			auto parsed = parseArchiveVirtualPath(spec.fileName);
			return parsed.isVirtual ? "" : parsed.physicalPath;
		}
		catch (Exception)
			return "";
	}

	/** Get the first existing filename from sorted file entries.
	 *
	 * Returns: first existing filename, or "" for an empty set.
	 */
	string getFirstExistingFileName() @safe
	{
		import std.algorithm.sorting : sort;

		auto ef = this.getExistingFiles();
		auto rs = ef.length ? ef[0].fileName : "";
		return rs;
	}

	/** Get the first openable file name from sorted file entries.
	 *
	 * Archive members behind the virtual `archive!/member` grammar are not
	 * openable as regular files; their digests and signatures are filled in
	 * by the archive scan of the container. Only physical paths count here.
	 *
	 * Returns: first existing physical filename, or "" for an empty set.
	 */
	string getFirstOpenableFileName() @safe
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (fileSpecs.length == 0)
			return "";
		string[] names;
		foreach (spec; fileSpecs)
		{
			auto path = physicalPathForSpec(spec);
			if (path.length > 0 && exists(path))
				names ~= path;
		}
		if (names.length == 0)
			return "";
		names.sort;
		return names[0];
	}

	/** Find a filename in a set of fileSpecs.
	 *
	 * Params:
	 *     filename = Stored or physical name to look for.
	 * Returns: `true` when a matching spec exists; virtual-grammar specs also
	 *     match their parsed physical path.
	 */
	bool hasFileName(string filename) @safe
	{
		import std.algorithm.searching : find;

		bool rc = false;
		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (found.length)
			rc = true;
		if (!rc && fileSpecsUseArchiveVirtualGrammar)
			foreach (spec; fileSpecs)
			{
				const path = physicalPathForSpec(spec);
				if (path.length > 0 && path == filename)
					return true;
			}
		return rc;
	}

	/** Get a FileSpec by its filename.
	 *
	 * Params:
	 *     filename = Stored or physical name to look for.
	 * Returns: The matching spec, or `null` when none matches.
	 */
	FileSpec getFileSpec(string filename) @safe
	{
		import std.algorithm.searching : find;

		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (found.length)
			return found[0];
		if (fileSpecsUseArchiveVirtualGrammar)
			foreach (spec; fileSpecs)
			{
				const path = physicalPathForSpec(spec);
				if (path.length > 0 && path == filename)
					return spec;
			}
		return null;
	}

	/** Add a FileSpec by its filename
	 *
	 * Params:
	 *   filename = filename to add
	 *   timeLastModified = modification time
	 * Returns:
	 *   newly created FileSpec
	 */
	FileSpec addFileSpec(string filename, string timeLastModified) @safe
	{
		import std.string : format, replace;

		enforce(!this.hasFileName(filename),
			"FileSpec with filename '%s' already exists.".format(filename));

		auto fileNameToStore = fileSpecsUseArchiveVirtualGrammar
			? escapeArchiveVirtualPath(nativePathToStoragePath(filename)) : filename;
		auto fs = new FileSpec(fileNameToStore, timeLastModified);
		this.fileSpecs ~= fs;
		this.fileSpecs.sort;
		return fs;
	}

	/** Delete a FileSpec by its filename
	 *
	 * Params:
	 *   filename = filename to delete
	 * Returns: the deleted FileSpec, or null if not found
	 */
	FileSpec deleteFileSpec(string filename) @safe
	{
		import std.algorithm.searching : find;
		import std.algorithm : remove;

		alias matcher = (a, b) => a.fileName == b;
		auto found = this.fileSpecs.find!(matcher, FileSpec[], string)(filename);
		if (!found.empty)
		{
			auto fs = found[0];
			this.fileSpecs = this.fileSpecs.filter!(a => a.fileName != filename).array;
			this.fileSpecs.sort;
			return fs;
		}
		if (fileSpecsUseArchiveVirtualGrammar)
			foreach (index, spec; fileSpecs)
				if (physicalPathForSpec(spec) == filename)
				{
					fileSpecs = fileSpecs[0 .. index] ~ fileSpecs[index + 1 .. $];
					return spec;
				}
		return null;
	}

}

@("class MediaInfoSig")
unittest
{
	import std.string : format, empty;

	auto ts = SysTime(1_234_567).toISOExtString;
	auto ts2 = SysTime(2_345_678).toISOExtString;

	auto mis0 = new NamedBinaryBlob();
	assert(mis0.toString == `NamedBinaryBlob('', 0, , CheckSums("", "", ""), fileType='', MI=null, AR=[], TO=null)`, mis0
			.toString);
	auto mis1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	assert(mis1.toString == format(
			"NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=null, AR=[], TO=null)", ts),
		mis1.toString);
	auto mis2 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567));
	assert(mis2.toString == format(
			"NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=null, AR=[], TO=null)", ts),
		mis2.toString);
	auto mis3 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567), CheckSums());
	assert(mis3.toString == format(
			"NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=null, AR=[], TO=null)", ts),
		mis3.toString);
	auto mis4 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567), CheckSums("a", "b", "c"), new MediaInfoSig());
	assert(
		mis4.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"a\", \"b\", \"c\"), fileType='', MI=MediaInfoSig(), AR=[], TO=null)", ts),
		mis4.toString);
	auto mis5 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567), CheckSums());
	assert(mis5.toString == format(
			"NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=null, AR=[], TO=null)", ts),
		mis5.toString);
	auto mis6 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567), CheckSums(), new MediaInfoSig());
	assert(
		mis6.toString == format("NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=MediaInfoSig(), AR=[], TO=null)", ts),
		mis6.toString);

	auto mis10 = new NamedBinaryBlob(mis4);
	assert(mis10 == mis4, "Same contents");
	assert(&mis10 != &mis4, "Same objects?");

	auto mis11 = mis4.dup;
	assert(mis11 == mis4, "Same contents");
	assert(&mis11 != &mis4, "Same objects?");

	auto hashBlob1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567), CheckSums("a", "b", "c"));
	auto hashBlob2 = new NamedBinaryBlob("file2", 1234, SysTime(2_345_678), CheckSums("a", "b", "c"));
	assert(hashBlob1 == hashBlob2, "Blob equality mismatch");
	assert(hashBlob1.toHash == hashBlob2.toHash, "Blob hash mismatch");

	auto passwordBlob = new NamedBinaryBlob("archive.zip", 1234,
		SysTime(1_234_567));
	passwordBlob.archivePassword = "correct horse battery staple";
	auto passwordCopy = new NamedBinaryBlob(passwordBlob);
	assert(passwordCopy.archivePassword == passwordBlob.archivePassword);
	auto passwordJson = toJSONString(passwordBlob);
	auto passwordRoundTrip = fromJSONString!NamedBinaryBlob(passwordJson);
	assert(passwordRoundTrip.archivePassword == passwordBlob.archivePassword);

	auto mis12 = new NamedBinaryBlob(["file2", "file8", "file1"], 1234, SysTime(1_234_567));
	assert(mis12.getFirstFileName == "file1");
	assert(mis12.toString == format(
			"NamedBinaryBlob('file1', 1234, %s, CheckSums(\"\", \"\", \"\"), fileType='', MI=null, AR=[], TO=null)", ts),
		mis12.toString);

	assert(mis12.hasFileName("file8"));
	assert(!mis12.hasFileName("file9"));
	assert(mis12.getFileSpec("file8") !is null);
	assert(mis12.getFileSpec("file9") is null);

	auto fs = mis12.addFileSpec("file9", SysTime(2_345_678).toISOExtString);
	assert(fs !is null);
	assert(mis12.hasFileName("file9"));
	fs = mis12.deleteFileSpec("file8");
	assert(fs !is null);
	fs = mis12.deleteFileSpec("file8");
	assert(fs is null);
	assert(!mis12.hasFileName("file8"));
	assert(mis12.fileSpecs.length == 3);
	assert(mis12.fileSpecs[0].fileName == "file1");
	assert(mis12.fileSpecs[1].fileName == "file2");
	assert(mis12.fileSpecs[2].fileName == "file9");
	assert(mis12.fileSpecs[0].timeLastModified == ts);
	assert(mis12.fileSpecs[1].timeLastModified == ts);
	assert(mis12.fileSpecs[2].timeLastModified == ts2);

	auto mis13 = new NamedBinaryBlob([
		"file2", "file8", "file1",
		"test/dummy-subtitle-file.srt", "test/dummy-text-file.txt"
	], 1234, SysTime(1_234_567));
	assert(mis13.fileSpecs.length == 5);
	auto en = mis13.getExistingFiles();
	assert(en.length == 2);

}

/* Trivial cases: empty blob, blob with non-existing file, blob with existing file, blob with mixed existing
   and non-existing files */
@("NamedBinaryBlob helper methods")
unittest
{
	auto emptyBlob = new NamedBinaryBlob();
	assert(emptyBlob.isBlobOrphaned);
	assert(emptyBlob.getFirstFileName == "");
	assert(emptyBlob.getFirstFileModDate == "");
	assert(emptyBlob.getFirstExistingFileName == "");

	auto nonExistentBlob = new NamedBinaryBlob("test/does-not-exist.txt", 12, SysTime(1_234_567));
	assert(nonExistentBlob.isBlobOrphaned);
	assert(nonExistentBlob.getFirstFileName == "test/does-not-exist.txt");
	assert(nonExistentBlob.getFirstFileModDate == SysTime(1_234_567).toISOExtString);
	assert(nonExistentBlob.getFirstExistingFileName == "");

	auto existingBlob = new NamedBinaryBlob("test/dummy-text-file.txt", 12, SysTime(1_234_567));
	assert(!existingBlob.isBlobOrphaned);
	assert(existingBlob.getFirstFileName == "test/dummy-text-file.txt");
	assert(existingBlob.getFirstExistingFileName == "test/dummy-text-file.txt");
	assert(existingBlob.getFirstFileModDate == SysTime(1_234_567).toISOExtString);

	string[] mixedFiles = [
		"test/does-not-exist.txt",
		"test/dummy-text-file.txt"
	];
	auto mixedBlob = new NamedBinaryBlob(mixedFiles, 12, SysTime(1_234_567));
	assert(!mixedBlob.isBlobOrphaned);
	debug { import std.stdio : writeln; try { writeln(mixedBlob.getFirstExistingFileName); } catch (Exception) {} }
	assert(mixedBlob.getFirstExistingFileName == "test/dummy-text-file.txt");
}

@("virtual archive members are not openable and skip direct metadata")
unittest
{
	import std.file : exists;

	auto containerPath = escapeArchiveVirtualPath(
		nativePathToStoragePath("test/dummy-text-file.txt"));

	/* Purely virtual member next to an existing container: not openable, so
	 * digests, file type and media info must be skipped instead of opening
	 * the virtual path. */
	auto memberBlob = new NamedBinaryBlob();
	memberBlob.fileSpecsUseArchiveVirtualGrammar = true;
	memberBlob.fileSpecs = [new FileSpec(appendArchiveVirtualPath(
		containerPath, "member.bin", size_t.max), "")];
	memberBlob.fileSize = 42;
	assert(memberBlob.getFirstExistingFileName == containerPath ~ "!/member.bin");
	assert(memberBlob.getFirstOpenableFileName == "");
	updateDigests(memberBlob);
	assert(!memberBlob.checkSums.hasDigests);
	updateFileType(memberBlob);
	assert(memberBlob.fileType.empty);
	updateMediaInfo(memberBlob);
	assert(memberBlob.mediaInfoSig is null);

	/* Missing container makes the member unreachable. */
	auto lostBlob = new NamedBinaryBlob();
	lostBlob.fileSpecsUseArchiveVirtualGrammar = true;
	lostBlob.fileSpecs = [new FileSpec(appendArchiveVirtualPath(
		escapeArchiveVirtualPath(nativePathToStoragePath(
		"test/does-not-exist.7z")), "member.bin", size_t.max), "")];
	assert(lostBlob.getFirstExistingFileName == "");
	assert(lostBlob.getFirstOpenableFileName == "");

	/* A physical spec wins even when a virtual spec sorts first. */
	auto mixedBlob = new NamedBinaryBlob();
	mixedBlob.fileSpecsUseArchiveVirtualGrammar = true;
	mixedBlob.fileSpecs = [
		new FileSpec(containerPath ~ "!/member.bin", ""),
		new FileSpec(escapeArchiveVirtualPath(
		nativePathToStoragePath("test/dummy-text-file.txt")), ""),
	];
	assert(mixedBlob.getFirstOpenableFileName == "test/dummy-text-file.txt");
}

@("fixupDataClassArrayIn legacy fields")
unittest
{
	auto legacy = new NamedBinaryBlob();
	legacy.fileName = "test/dummy-text-file.txt";
	legacy.timeLastModified = SysTime(1_234_567).toISOExtString;
	legacy.fileNames = ["test/dummy-subtitle-file.srt"];
	legacy.md5sum_b64 = "a";
	legacy.sha1sum_b64 = "b";
	legacy.xxh64sum_b64 = "c";
	legacy.mediaInfo = ["<audio:0, 2 ch., 1 h, 0kbps ?, AAC>"];
	legacy.mediaInfoSig = null;
	legacy.torrentInfo = new TorrentInfo();
	legacy.torrentInfo.magnetURI = "";

	auto fixed = fixupDataClassArrayIn([legacy]);
	assert(fixed.length == 1);
	assert(fixed[0].fileSpecs.length == 2);
	assert(fixed[0].fileName.empty);
	assert(fixed[0].timeLastModified.empty);
	assert(fixed[0].checkSums.md5sum_b64 == "a");
	assert(fixed[0].checkSums.sha1sum_b64 == "b");
	assert(fixed[0].checkSums.xxh64sum_b64 == "c");
	assert(fixed[0].mediaInfoSig !is null);
	assert(fixed[0].torrentInfo is null);
}

/** Correct MediaInfo's classification of standalone JPEG image files.
 *
 * Some JPEG files are reported by MediaInfo as a video stream with JPEG format
 * instead of as an image stream. The file utility identifies these files more
 * reliably as still images, so use that result to repair the stream category.
 *
 * Params:
 *     obj = Blob record to repair in place; ignored when `null` or when no
 *         matching MediaInfo signature is present.
 */
package void normalizeJpegImageMediaInfo(NamedBinaryBlob obj)
{
	if (obj is null || obj.mediaInfoSig is null || !obj.fileType.startsWith("JPEG image data"))
		return;

	MediaInfoVideo[] remainingVideoStreams;
	foreach (stream; obj.mediaInfoSig.videoStreams)
	{
		if (stream !is null && stream.format == "JPEG")
		{
			obj.mediaInfoSig.imageStreams ~= new MediaInfoImage(
				stream.index, stream.format, stream.width, stream.height);
		}
		else
		{
			remainingVideoStreams ~= stream;
		}
	}
	obj.mediaInfoSig.videoStreams = remainingVideoStreams;
}

@("normalize JPEG image MediaInfo classification")
unittest
{
	auto image = new NamedBinaryBlob("photo.jpg", 1234, SysTime(1_234_567));
	image.fileType = "JPEG image data, JFIF standard 1.02, baseline, 350x333";
	image.mediaInfoSig = new MediaInfoSig();
	image.mediaInfoSig.videoStreams ~= new MediaInfoVideo(0, "", "JPEG", 350, 333);

	auto otherVideo = new MediaInfoVideo(1, "", "AV1", 1920, 1080);
	image.mediaInfoSig.videoStreams ~= otherVideo;

	normalizeJpegImageMediaInfo(image);
	assert(image.mediaInfoSig.imageStreams.length == 1);
	assert(image.mediaInfoSig.imageStreams[0].format == "JPEG");
	assert(image.mediaInfoSig.imageStreams[0].width == 350);
	assert(image.mediaInfoSig.imageStreams[0].height == 333);
	assert(image.mediaInfoSig.videoStreams.length == 1);
	assert(image.mediaInfoSig.videoStreams[0] is otherVideo);

	normalizeJpegImageMediaInfo(image);
	assert(image.mediaInfoSig.imageStreams.length == 1);
}

/* ----------------------------------------------------------------------- */

/* ----------------------------------------------------------------------- */

/** Sort an array of NamedBinaryBlob objects by their filenames
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to sort
 * Returns: Sorted array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] sortDataClassArrayByFileName(NamedBinaryBlob[] dataArray)
{
	import std.algorithm.sorting : sort;
	import std.algorithm.mutation : SwapStrategy;

	alias myCmp = (a, b) {
		return a.getFirstFileName < b.getFirstFileName;
	};
	auto sortedData_rng = sort!(myCmp, SwapStrategy.unstable,
		typeof(dataArray))(dataArray);

	import std.algorithm.mutation : copy;

	NamedBinaryBlob[] sortedData;
	sortedData.length = dataArray.length;
	copy(sortedData_rng, sortedData);

	return sortedData;
}

@("sortDataClassArrayByFileName")
unittest
{
	auto mis0 = new NamedBinaryBlob("file8", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob("file1", 2345, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file2", "file3"], 3456, SysTime(1_234_567));
	auto sl = sortDataClassArrayByFileName([mis0, mis1, mis2]);
	assert(sl.length == 3);
	assert(sl[0].getFirstFileName == "file1");
	assert(sl[1].getFirstFileName == "file2");
	assert(sl[2].getFirstFileName == "file8");
}

/** Remove duplicate entries from NamedBinaryBlob array by their filenames
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Array of NamedBinaryBlob objects with unique filenames
 */
NamedBinaryBlob[] uniqDataClassArrayByFileName(NamedBinaryBlob[] dataArray)
{
	import std.algorithm.iteration : uniq;
	import std.array : array;

	enum myEqual = "a.getFirstFileName == b.getFirstFileName";
	return uniq!(myEqual, typeof(dataArray))(dataArray).array;
}

@("uniqDataClassArrayByFileName")
unittest
{
	auto mis0 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob("file1", 2345, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file2", "file3"], 3456, SysTime(1_234_567));
	auto sl = uniqDataClassArrayByFileName([mis0, mis1, mis2]);
	assert(sl.length == 2);
	assert(sl[0].getFirstFileName == "file1");
	assert(sl[0].fileSize == 1234);
	assert(sl[1].getFirstFileName == "file2");
	assert(sl[1].fileSize == 3456);
}
