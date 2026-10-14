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
import std.datetime.systime : SysTime;
import std.datetime.timezone : TimeZone;
import std.exception : assertThrown, enforce;
import std.string : startsWith;

import jsonizer;

import dosierarkivo;
import dosierarkivo.archive : appendArchiveVirtualPath,
    escapeArchiveVirtualPath, normalizeArchiveEntryPath, parseArchiveVirtualPath;
import dosierskanilo.catalogbackend : ArchiveEntryId, ContentId,
    ContentLocator, ReferenceId;
import dosierskanilo.logging;
import dosierskanilo.options;
import dosierskanilo.progress;
import dosierskanilo.membercontentcache : MemberContentCache,
    MemberContentLease, MemberContentNotExtractableException,
    sharedMemberContentCache;
import dosierskanilo.metadata.digests;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
public import dosierskanilo.model.archivespec;
public import dosierskanilo.model.checksums;
public import dosierskanilo.model.filespec;

enum int DATA_CLASS_VERSION1 = 1; ///< Current version of the NamedBinaryBlob structure, v1
enum int DATA_CLASS_VERSION2 = 2; ///< Current version of the NamedBinaryBlob structure, v2
enum int DATA_CLASS_VERSION3 = 3; ///< Legacy NamedBinaryBlob representation, v3
enum int DATA_CLASS_VERSION4 = 4; ///< Recursive archive-member representation, v4
enum int DATA_CLASS_VERSION5 = 5; ///< Current virtual-reference representation, v5

/** Wrapper class to serialize an array of NamedBinaryBlob objects
 *
 * This class wraps the data array together with global metadata that describes
 * the environment the data was collected with.
 */
struct NamedBinaryBlobWrapper
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
		import dosierskanilo.metadata.fileutilsig : getFileUtilityVersion;
		fileUtilityVersion = getFileUtilityVersion();
	}
}

alias NamedBinaryBlobCatalog = NamedBinaryBlobWrapper;

@("struct NamedBinaryBlobWrapper")
unittest
{
	auto mis0 = new NamedBinaryBlob();
	auto mis1 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis2 = new NamedBinaryBlob(["file1", "file2"], 1234, SysTime(1_234_567));
	auto mis3 = new NamedBinaryBlob([
		new FileSpec("file8", SysTime(1_234_567)),
		new FileSpec("file9", SysTime(2_234_567))
	], 1234);
	auto wrap = NamedBinaryBlobWrapper(DATA_CLASS_VERSION3, [
		mis0, mis1, mis2, mis3
	]);
	assert(wrap.dataVersion == DATA_CLASS_VERSION3);
	assert(wrap.dataArray.length == 4);
	assert(wrap.mediaInfoVersion.length == 0);
	assert(wrap.fileUtilityVersion.length == 0);
}

/// Helper variables of the class
mixin template payloadHelpers()
{
	import std.parallelism : Task, task;

	Task!(updateDigests, NamedBinaryBlob, shared(bool)*, ProgressCallBack*)* task_hashme; ///< Pointer to hashing job
	Task!(updateFileType, NamedBinaryBlob)* task_filetype; /// Query filetype with 'file' utility
	Task!(updateMediaInfo, NamedBinaryBlob, bool)* task_mediasig; ///< Pointer to mediasig job
	Task!(updateArchives, NamedBinaryBlob, bool, bool, shared(bool)*, ProgressCallBack*,
		ArchivePasswordCallback, size_t, size_t, string, MemberContentCache, bool,
		bool)* task_archiveScan; ///< Pointer to archive scan job
	Task!(updateTorrentInfo, NamedBinaryBlob)* task_torrentscan; ///< Pointer to torrent scan job
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
		fileSpecs = other.fileSpecs;
		fileNames = other.fileNames;
		fileSize = other.fileSize;
		timeLastModified = other.timeLastModified;
		checkSums = other.checkSums;
		fileType = other.fileType;
		mediaInfoSig = other.mediaInfoSig;
		torrentInfo = other.torrentInfo;
		archivePassword = other.archivePassword;
		archiveIndexKnown = other.archiveIndexKnown;
		archiveIndexDeep = other.archiveIndexDeep;
		fileSpecsUseArchiveVirtualGrammar = other.fileSpecsUseArchiveVirtualGrammar;
		if (other.archiveSpecs !is null)
		{
			archiveSpecs = [];
			foreach (entry; other.archiveSpecs)
				archiveSpecs ~= entry is null ? null : entry.dup();
		}
	}

	/* ------------------------------------------------------------------- */

	/** create a string from the object contents */
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
					const auto path = physicalPathForSpec(spec);
					if (path.length > 0 && exists(path))
						rs ~= new FileSpec(path, spec.timeLastModified);
				}
			if (rs.length > 1)
				rs.sort;
		}
		return rs;
	}

	private string physicalPathForSpec(FileSpec spec) const @safe
	{
		if (spec is null || spec.fileName.length == 0)
			return "";
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

	/** Find a filename in a set of fileSpecs
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
				if (physicalPathForSpec(spec) == filename)
					return true;
		return rc;
	}

	/** Get a FileSpec by its filename
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
				if (physicalPathForSpec(spec) == filename)
					return spec;
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
			? escapeArchiveVirtualPath(filename.replace('\\', '/')) : filename;
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
 */
private void normalizeJpegImageMediaInfo(NamedBinaryBlob obj)
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
		assert(a.fileSpecs.length > 0,
			"NamedBinaryBlob entry a has no filenames!");
		assert(b.fileSpecs.length > 0,
			"NamedBinaryBlob entry b has no filenames!");

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
	import std.algorithm.mutation : copy;

	NamedBinaryBlob[] uniqSortedData;
	uniqSortedData.length = dataArray.length;
	enum myEqual = "a.getFirstFileName == b.getFirstFileName";
	auto uniqSortedData_rng = uniq!(myEqual, typeof(dataArray))(
		dataArray);
	const auto remainingRng = copy(uniqSortedData_rng, uniqSortedData);
	uniqSortedData.length -= remainingRng.length;
	return uniqSortedData;
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

version (unittest)
{
	enum json_file_v0 = "./test/json_file_v0.json";
	enum json_file_v1 = "./test/json_file_v1.json";
	enum json_file_v2 = "./test/json_file_v2.json";
	enum json_file_v2_archive = "./test/json_file_v2_archive.json";
	enum json_file_v2_torrent = "./test/json_file_v2_torrent.json";
	auto test_json_v0 = import(json_file_v0);
	auto test_json_v1 = import(json_file_v1);
	auto test_json_v2 = import(json_file_v2);
	auto test_json_v2_archive = import(json_file_v2_archive);
	auto test_json_v2_torrent = import(json_file_v2_torrent);
}

/** Fixup legacy fields in NamedBinaryBlob array for deserialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayIn(NamedBinaryBlob[] dataArray)
{
	// -- Fixup legacy fields ---------------------------
	foreach (ref obj; dataArray)
	{
		// -- Fixup legacy filename field ---------------------------
		/* The same data blob may have been stored with either a single
		 * filename (fileName) or multiple filenames (fileNames).
		 * We convert all entries to use the fileNames array.
		 */
		if (obj.fileName.empty == false)
		{
			obj.fileSpecs ~= new FileSpec(obj.fileName, obj.timeLastModified);
			obj.fileName = null;
			obj.timeLastModified = null;
		}
		// -- Fixup legacy 2 - filenames and dates must be together --
		if (obj.fileNames.empty == false)
		{
			foreach (fn; obj.fileNames)
				obj.fileSpecs ~= new FileSpec(fn, obj.timeLastModified);
			obj.fileNames = [];
			obj.timeLastModified = null;
		}

		// -- Fixup legacy digest fields ---------------------------
		if (obj.md5sum_b64 !is null && !obj.md5sum_b64.empty)
		{
			obj.checkSums.md5sum_b64 = obj.md5sum_b64;
		}
		if (obj.sha1sum_b64 !is null && !obj.sha1sum_b64.empty)
		{
			obj.checkSums.sha1sum_b64 = obj.sha1sum_b64;
		}
		if (obj.xxh64sum_b64 !is null && !obj.xxh64sum_b64.empty)
		{
			obj.checkSums.xxh64sum_b64 = obj.xxh64sum_b64;
		}

		// -- Fixup legacy mediaInfo field ---------------------------
		if (obj.mediaInfo !is null && obj.mediaInfo.length > 0)
		{
			obj.mediaInfoSig = parseMediaInfoSignature(obj.mediaInfo);
		}

		// -- Fixup some broken entries ---------------------------
		if (obj.mediaInfoSig !is null)
		{
			with (obj.mediaInfoSig)
			{
				foreach (v; imageStreams)
					if (v.index == -1)
						v.index = 0;
				foreach (v; videoStreams)
					if (v.index == -1)
						v.index = 0;
				foreach (v; audioStreams)
					if (v.index == -1)
						v.index = 0;
				foreach (v; textStreams)
					if (v.index == -1)
						v.index = 0;
			}
		}
		normalizeJpegImageMediaInfo(obj);
		//-- filter empty mediaInfoSig ---------------------------
		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.magnetURI.empty))
		{
			obj.torrentInfo = null;
		}
	}

	return dataArray;
}

/** Fixup NamedBinaryBlob array before serialization
 *
 * Params:
 *   dataArray = Array of NamedBinaryBlob objects to process
 * Returns: Updated array of NamedBinaryBlob objects
 */
NamedBinaryBlob[] fixupDataClassArrayOut(NamedBinaryBlob[] dataArray)
{
	// -- Fixup legacy fields ---------------------------
	foreach (ref obj; dataArray)
	{
		// -- Clear legacy filename field ---------------------------
		if (obj.fileSpecs.length > 1)
		{
			obj.fileName = "";
			obj.timeLastModified = "";
		}
		// -- We have just a single name, setup the single filename --
		else
		{
			obj.fileName = obj.fileSpecs[0].fileName;
			obj.timeLastModified = obj.fileSpecs[0].timeLastModified;
			obj.fileSpecs = [];
		}
		assert(obj.fileNames.length == 0, "fileNames are of service.");

		// -- Clear legacy digest fields ---------------------------
		obj.md5sum_b64 = null;
		obj.sha1sum_b64 = null;
		obj.xxh64sum_b64 = null;

		// -- Clear legacy mediaInfo field ---------------------------
		obj.mediaInfo = null;

		normalizeJpegImageMediaInfo(obj);

		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
		{
			obj.mediaInfoSig = null;
		}

		// -- Fixup broken torrent entries ---------------------------
		if ((obj.torrentInfo !is null) && (obj.torrentInfo.magnetURI.empty))
		{
			obj.torrentInfo = null;
		}
	}

	return dataArray;
}

@("fixupDataClassArrayOut")
unittest
{
	auto mis0 = new NamedBinaryBlob("file1", 1234, SysTime(1_234_567));
	auto mis1 = new NamedBinaryBlob(["file2", "file3"], 2345, SysTime(1_234_567));
	auto dca = fixupDataClassArrayOut([mis0, mis1]);
	assert(dca[0].fileName == "file1");
	assert(dca[0].timeLastModified == SysTime(1_234_567).toISOExtString);
	assert(dca[0].fileSpecs.length == 0);
	assert(dca[1].fileName == "");
	assert(dca[1].timeLastModified == "");
	assert(dca[1].fileSpecs.length == 2);
}

/** Deserialize a JSON string into the global wrapper structure.
 *
 * Params:
 *   serializedData = JSON string with serialized NamedBinaryBlob data
 * Returns:
 *   wrapper object with deserialized NamedBinaryBlob data and metadata
 */
NamedBinaryBlobCatalog deserializeDataClassJsonWrapperString(const string serializedData)
{
	NamedBinaryBlobCatalog wrapper;

	if (serializedData.length == 0)
		return wrapper;

	// Check for new JSON object format
	if (serializedData[0] != '[')
	{
		logLineVerbose("  Reading into NamedBinaryBlobCatalog object (new format)...");
		import std.json : JSONType, parseJSON;
		import std.conv : to;

		auto json = parseJSON(serializedData);
		if (json.type != JSONType.object)
			assert(false, "Unexpected JSON root type.");

		wrapper.dataVersion = DATA_CLASS_VERSION3;
		if ("dataVersion" in json.object)
			wrapper.dataVersion = cast(ulong) json.object["dataVersion"].integer;
		if ("mediaInfoVersion" in json.object)
			wrapper.mediaInfoVersion = json.object["mediaInfoVersion"].str;
		if ("fileUtilityVersion" in json.object)
			wrapper.fileUtilityVersion = json.object["fileUtilityVersion"].str;
		if ("dataArray" in json.object)
			wrapper.dataArray = fromJSONString!(NamedBinaryBlob[])(json.object["dataArray"].toString);

		if (wrapper.dataVersion == DATA_CLASS_VERSION1)
			wrapper.dataVersion = DATA_CLASS_VERSION2;

		if (wrapper.dataVersion != DATA_CLASS_VERSION2
			&& wrapper.dataVersion != DATA_CLASS_VERSION3
			&& wrapper.dataVersion != DATA_CLASS_VERSION4
			&& wrapper.dataVersion != DATA_CLASS_VERSION5)
			assert(false, "Data version mismatch, expected " ~ to!string(
				DATA_CLASS_VERSION2) ~ ", " ~ to!string(DATA_CLASS_VERSION3)
				~ ", " ~ to!string(DATA_CLASS_VERSION4) ~ " or "
				~ to!string(DATA_CLASS_VERSION5) ~ ", got "
				~ to!string(wrapper.dataVersion));
	}
	// Check for old plain array JSON
	else if (serializedData[0] == '[')
	{
		logLineVerbose("  Reading directly into NamedBinaryBlob[] array (legacy format)...");
		wrapper.dataArray = fromJSONString!(NamedBinaryBlob[])(serializedData);
		wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
		wrapper.dataVersion = DATA_CLASS_VERSION3;
	}
	// Shouldn't happen
	else
		assert(false, "Unknow JSON format?");

	wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
	if (wrapper.dataVersion == DATA_CLASS_VERSION5)
		foreach (blob; wrapper.dataArray)
			if (blob !is null)
				blob.fileSpecsUseArchiveVirtualGrammar = true;
	logFLineVerbose("  got %d entries in array after deserialization() of archive data.", wrapper.dataArray.length);

	return wrapper;
}

/** Deserialize a JSON string and return NamedBinaryBlob[] array
 *
 * Params:
 *   serializedData = JSON string with serialized NamedBinaryBlob data
 * Returns:
 *   array of deserialized NamedBinaryBlob objects
 */
NamedBinaryBlob[] deserializeDataClassJsonString(const string serializedData)
{
	return deserializeDataClassJsonWrapperString(serializedData).dataArray;
}

/** Deserialize a JSON file and return NamedBinaryBlobCatalog object.
 *
 * Params:
 *   fileName = the name of JSON file to read.
 *   verbose = enable verbose logging
 * Returns:
 *   wrapper with deserialized NamedBinaryBlob data and metadata, or an empty wrapper when file is missing
 */
NamedBinaryBlobCatalog deserializeDataClassJsonWrapperFile(string fileName)
{
	import std.file : exists, readText;

	logFLineVerbose("Read serialized data from JSON file %s", fileName);
	if (!exists(fileName))
		return NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);

	const string serializedData = readText(fileName);
	return deserializeDataClassJsonWrapperString(serializedData);
}


@("deserializeDataClassJsonString")
unittest
{
	auto dca0 = deserializeDataClassJsonString(test_json_v0);
	assert(dca0.length == 3);

	auto dca1 = deserializeDataClassJsonString(test_json_v1);
	assert(dca1.length == 3);

	auto dca2 = deserializeDataClassJsonString(test_json_v2);
	assert(dca2.length == 3);

	auto s0 = sortDataClassArrayByFileName(dca0);
	auto s1 = sortDataClassArrayByFileName(dca1);
	auto s2 = sortDataClassArrayByFileName(dca2);
	foreach (index; 0 .. s0.length)
	{
		assert(s0[index].toString == s1[index].toString, s0[index].toString ~ " != " ~ s1[index].toString);
		assert(s0[index].toString == s2[index].toString, s0[index].toString ~ " != " ~ s2[index].toString);
	}
}

/** Deserialize a JSON file and return NamedBinaryBlob[] array
 *
 * Params:
 *   fileName = the name of JSON file to read.
 *   verbose = enable verbose logging
 * Returns:
 *   array of deserialized NamedBinaryBlob objects, or empty array when file is missing
 */
NamedBinaryBlob[] deserializeDataClassJsonFile(string fileName, bool verbose = false)
{
	import std.file : exists, readText;

	logFLineVerbose("Read serialized data from JSON file %s", fileName);
	//enforce(exists(fileName), "File %s does not exist!".format(fileName));
	if (!exists(fileName))
		return [];

	logFLineVerbose("  reading file '%s' into the serializer archive container", fileName);
	const string serializedData = readText(fileName);

	return deserializeDataClassJsonString(serializedData);
}

private string canonicalV5FilePath(string fileName, bool fromLegacyVersion)
{
	import std.string : replace;

	if (fromLegacyVersion)
		return escapeArchiveVirtualPath(fileName.replace('\\', '/'));

	const auto parsed = parseArchiveVirtualPath(fileName);
	auto result = escapeArchiveVirtualPath(parsed.physicalPath);
	foreach (entry; parsed.entries)
		result = appendArchiveVirtualPath(result, entry.relativePath,
			entry.hasOccurrence ? entry.occurrence : size_t.max);
	return result;
}

private string archiveVirtualIdentityKey(string path)
{
	return "safe\0" ~ path;
}

private void appendArchiveMemberBlobs(ref NamedBinaryBlob[] result,
	ArchiveSpec[] entries, string containerPath, size_t depth = 0)
{
	enforce(depth < 32,
		"Nested archive conversion exceeds the maximum depth.");
	size_t[string] pathCounts;
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
			isDirectory);
		if (safe && !isDirectory)
		{
			const auto key = archiveVirtualIdentityKey(path);
			pathCounts[key] = pathCounts.get(key, 0) + 1;
		}
	}

	size_t[string] nextOccurrence;
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
			isDirectory);
		if (!safe || isDirectory)
			continue;

		const auto key = archiveVirtualIdentityKey(path);
		size_t occurrence;
		if (entry.hasIndexIdentity)
			occurrence = entry.occurrence;
		else
			occurrence = nextOccurrence.get(key, 0);
		nextOccurrence[key] = occurrence + 1;
		const bool includeOccurrence = pathCounts.get(key, 0) > 1
			|| occurrence > 0;
		const auto memberPath = appendArchiveVirtualPath(containerPath, path,
			includeOccurrence ? occurrence : size_t.max);

		auto member = new NamedBinaryBlob();
		member.fileSize = entry.fileSize;
		member.checkSums = entry.checkSums;
		member.fileType = entry.fileType;
		if (entry.mediaInfoSig !is null)
			member.mediaInfoSig = entry.mediaInfoSig.dup;
		member.fileSpecs = [new FileSpec(memberPath, entry.timeLastModified)];
		member.archivePassword = entry.archivePassword;
		member.archiveIndexKnown = entry.nestedEntries !is null
			|| entry.archivePassword.length > 0;
		member.archiveIndexDeep = entry.nestedEntries !is null
			&& archiveEntriesHaveCompleteChecksums(entry.nestedEntries);
		member.fileSpecsUseArchiveVirtualGrammar = true;
		result ~= member;

		if (entry.nestedEntries !is null)
			appendArchiveMemberBlobs(result, entry.nestedEntries, memberPath,
				depth + 1);
	}
}

/** Convert legacy nested ArchiveSpec trees into ordinary JSON-v5 blob references. */
private NamedBinaryBlob[] normalizeV5Catalog(NamedBinaryBlob[] blobs,
	bool sourceAlreadyV5)
{
	NamedBinaryBlob[] records;
	foreach (blob; blobs)
	{
		if (blob is null)
			continue;
		fixupDataClassArrayIn([blob]);
		foreach (spec; blob.fileSpecs)
			if (spec !is null && spec.fileName.length > 0)
				spec.fileName = canonicalV5FilePath(spec.fileName,
					!sourceAlreadyV5);
		blob.fileSpecsUseArchiveVirtualGrammar = true;

		auto archiveEntries = blob.archiveSpecs;
		if (archiveEntries !is null && blob.fileSpecs.length == 0)
			throw new Exception("An archive index cannot be promoted without a "
				~ "containing FileSpec reference.");
		if (archiveEntries !is null)
		{
			blob.archiveIndexKnown = true;
			blob.archiveIndexDeep = archiveEntriesHaveCompleteChecksums(
				archiveEntries);
			blob.archiveSpecs = null;
		}
		records ~= blob;

		if (archiveEntries !is null)
			foreach (containerSpec; blob.fileSpecs)
				if (containerSpec !is null && containerSpec.fileName.length > 0)
					appendArchiveMemberBlobs(records, archiveEntries,
						containerSpec.fileName);
	}

	return sortDataClassArrayByFileName(records);
}

private bool archiveEntriesHaveCompleteChecksums(ArchiveSpec[] entries)
{
	foreach (entry; entries)
	{
		if (entry is null)
			continue;
		bool safe;
		bool isDirectory;
		normalizeArchiveEntryPath(entry.fileName, safe, isDirectory);
		if (!safe || isDirectory)
			continue;
		if (!entry.checkSums.hasDigests)
			return false;
		if (entry.nestedEntries !is null
			&& !archiveEntriesHaveCompleteChecksums(entry.nestedEntries))
			return false;
	}
	return true;
}

private NamedBinaryBlob[] fixupDataClassArrayOutV5(
	NamedBinaryBlob[] dataArray)
{
	foreach (ref obj; dataArray)
	{
		obj.fileName = null;
		obj.timeLastModified = null;
		obj.fileNames = null;
		obj.md5sum_b64 = null;
		obj.sha1sum_b64 = null;
		obj.xxh64sum_b64 = null;
		obj.mediaInfo = null;
		normalizeJpegImageMediaInfo(obj);
		if (obj.mediaInfoSig !is null && obj.mediaInfoSig.empty)
			obj.mediaInfoSig = null;
		if (obj.torrentInfo !is null && obj.torrentInfo.magnetURI.empty)
			obj.torrentInfo = null;
	}
	return dataArray;
}

/** Promote a deserialized version-0..5 catalog to the canonical JSON-v5 model. */
void upgradeDataClassCatalogToV5(ref NamedBinaryBlobCatalog wrapper)
{
	if (wrapper.dataVersion < DATA_CLASS_VERSION2
		|| wrapper.dataVersion > DATA_CLASS_VERSION5)
		throw new Exception("Unsupported JSON catalog version.");
	const bool sourceAlreadyV5 = wrapper.dataVersion == DATA_CLASS_VERSION5;
	wrapper.dataArray = normalizeV5Catalog(wrapper.dataArray, sourceAlreadyV5);
	wrapper.dataVersion = DATA_CLASS_VERSION5;
}

/** Serialize the wrapper object into a JSON file.
 *
 * Store the wrapper data in a JSON file.
 * Params:
 *   fileName = The filename for the JSON
 *   wrapper = Wrapper object to serialize
 */
void serializeDataClassWrapperFile(string fileName, ref NamedBinaryBlobCatalog wrapper)
{
	logFLineVerbose("Generate JSON data and write it to file %s", fileName);
	if (wrapper.dataVersion == 0)
		wrapper.dataVersion = DATA_CLASS_VERSION5;
	upgradeDataClassCatalogToV5(wrapper);
	wrapper.refreshRuntimeMetadata();

	logFLineVerbose("  sort and uniq serialized array by their filenames (use a range)");
	auto sortedDeserializedData_rng = sortDataClassArrayByFileName(wrapper.dataArray);
	auto uniqSortedDeserializedData = uniqDataClassArrayByFileName(sortedDeserializedData_rng);
	wrapper.dataArray = fixupDataClassArrayOutV5(uniqSortedDeserializedData);
	writeJSON!(NamedBinaryBlobWrapper)(fileName, wrapper);
	wrapper.dataArray = fixupDataClassArrayIn(wrapper.dataArray);
	foreach (blob; wrapper.dataArray)
		if (blob !is null)
			blob.fileSpecsUseArchiveVirtualGrammar = true;
}

@("JSON v5 promotes nested and duplicate archive members to virtual references")
unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto fileName = buildPath(tempDir(), "nested-archive-v5-"
		~ randomUUID().toString() ~ ".json");
	scope (exit)
		if (exists(fileName))
			remove(fileName);

	auto member = new ArchiveSpec("nested/readme.txt", 11, "",
		CheckSums("md5", "sha1", "xxh64"));
	auto duplicateMember = new ArchiveSpec("nested/readme.txt", 11, "",
		CheckSums("md5", "sha1", "xxh64"));
	auto deepMember = new ArchiveSpec("deep/readme!.txt", 5, "",
		CheckSums.init);
	auto nestedArchive = new ArchiveSpec("nested.zip", 64, "",
		CheckSums.init);
	nestedArchive.nestedEntries = [deepMember];
	auto blob = new NamedBinaryBlob();
	blob.fileSize = 256;
	blob.fileSpecs = [new FileSpec("container!.zip", "")];
	blob.archiveSpecs = [member, duplicateMember, nestedArchive];
	auto v4 = NamedBinaryBlobCatalog(DATA_CLASS_VERSION4, [blob]);
	serializeDataClassWrapperFile(fileName, v4);
	assert(v4.dataVersion == DATA_CLASS_VERSION5);
	auto loaded = deserializeDataClassJsonWrapperFile(fileName);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	assert(loaded.dataArray.length == 5);
	string[] virtualPaths;
	bool foundArchiveIndexMarker;
	foreach (record; loaded.dataArray)
	{
		foundArchiveIndexMarker = foundArchiveIndexMarker
			|| record.archiveIndexKnown;
		foreach (spec; record.fileSpecs)
			virtualPaths ~= spec.fileName;
	}
	assert(virtualPaths.canFind("container!!.zip"));
	assert(virtualPaths.canFind("container!!.zip!/nested/readme.txt!~0"));
	assert(virtualPaths.canFind("container!!.zip!/nested/readme.txt!~1"));
	assert(virtualPaths.canFind("container!!.zip!/nested.zip"));
	assert(virtualPaths.canFind("container!!.zip!/nested.zip!/deep/readme!!.txt"));
	assert(foundArchiveIndexMarker);
}

@("JSON v5 decodes escaped physical exclamation marks for filesystem access")
unittest
{
	import std.file : exists, getSize, remove, tempDir, write;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto token = randomUUID().toString();
	const auto physicalPath = buildPath(tempDir(), "physical-literal!-"
		~ token ~ ".txt");
	const auto jsonPath = buildPath(tempDir(), "physical-literal-json-"
		~ token ~ ".json");
	scope (exit)
	{
		if (exists(physicalPath))
			remove(physicalPath);
		if (exists(jsonPath))
			remove(jsonPath);
	}
	write(physicalPath, "v5 physical path");
	auto blob = new NamedBinaryBlob();
	blob.fileSize = cast(size_t) getSize(physicalPath);
	blob.fileSpecs = [new FileSpec(physicalPath, "")];
	auto emptyArchive = new NamedBinaryBlob();
	emptyArchive.fileSpecs = [new FileSpec("empty!.zip", "")];
	emptyArchive.archiveIndexKnown = true;
	auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3,
		[blob, emptyArchive]);
	serializeDataClassWrapperFile(jsonPath, catalog);
	auto loaded = deserializeDataClassJsonWrapperFile(jsonPath);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	assert(loaded.dataArray.length == 2);
	bool foundPhysicalPath;
	bool foundEmptyArchiveIndex;
	foreach (restored; loaded.dataArray)
	{
		foreach (spec; restored.fileSpecs)
			if (spec.fileName == escapeArchiveVirtualPath(physicalPath))
			{
				foundPhysicalPath = true;
				assert(restored.getFirstExistingFileName == physicalPath);
				assert(restored.hasFileName(physicalPath));
			}
		foundEmptyArchiveIndex = foundEmptyArchiveIndex
			|| restored.archiveIndexKnown;
	}
	assert(foundPhysicalPath && foundEmptyArchiveIndex);
}

@("deserializeDataClassJsonFile")
unittest
{
	import core.exception : AssertError;
	import std.file : exists, readText, tempDir, getSize, getTimes, mkdirRecurse, rmdirRecurse;

	auto dca = deserializeDataClassJsonFile("./test/json_file_notexisting.json");
	assert(dca.length == 0);

	auto dca0 = deserializeDataClassJsonFile(json_file_v0);
	assert(dca0.length == 3);

	auto dca1 = deserializeDataClassJsonFile(json_file_v1);
	assert(dca1.length == 3);

	auto dca2 = deserializeDataClassJsonFile(json_file_v2);
	assert(dca2.length == 3);

	auto s0 = sortDataClassArrayByFileName(dca0);
	auto s1 = sortDataClassArrayByFileName(dca1);
	auto s2 = sortDataClassArrayByFileName(dca2);
	foreach (index; 0 .. s0.length)
	{
		assert(s0[index].toString == s1[index].toString, s0[index].toString ~ " != " ~ s1[index].toString);
		assert(s0[index].toString == s2[index].toString, s0[index].toString ~ " != " ~ s2[index].toString);
	}

	assertThrown!AssertError(deserializeDataClassJsonFile("./test/json_file_v1_wrongversion.json"), "No bumm?");
}

/** Serialize an array of NamedBinaryBlob classes
 *
 * Store the array data in a JSON file.
 * Params:
 *   fileName = The filename for the JSON
 *   dataArray = Array of NamedBinaryBlob objects to serialize
 */
void serializeDataClassArrayFile(string fileName, NamedBinaryBlob[] dataArray)
{
	auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, dataArray);
	serializeDataClassWrapperFile(fileName, wrapper);
}

version (unittest)
{
	void testSerializeDataClassArrayFile(string fileName, int expectedLength, string expectedJsonFile)
	{
		import std.conv : to;
		import std.file : mkdirRecurse, readText, remove, tempDir;
		import std.json : JSONValue, parseJSON;
		import std.path : buildPath;
		import std.uuid : randomUUID;

		auto dca1 = deserializeDataClassJsonString(fileName);
		assert(dca1.length == expectedLength, dca1.length.to!string);

		auto dir = buildPath(tempDir(), "filescanner_serializer_test");
		mkdirRecurse(dir);
		auto file = buildPath(dir, randomUUID().toString);
		scope (exit)
		{
			remove(file);
		}

		file.serializeDataClassArrayFile(dca1);
		//file.writeJSON(test_json_v2);

		auto jsonstring = file.readText;
		//writeln(jsonstring);
		auto json = jsonstring.parseJSON;

		auto jsonstring0 = expectedJsonFile.readText;
		auto json0 = jsonstring0.parseJSON;
		void normalizeSingleFileSpecShape(ref typeof(json) value)
		{
			auto records = value.object["dataArray"].array;
			foreach (ref record; records)
			{
				if ("fileSpecs" in record.object || !("fileName" in record.object))
					continue;
				JSONValue[string] fileSpecObject;
				fileSpecObject["fileName"] = record.object["fileName"];
				if ("timeLastModified" in record.object)
					fileSpecObject["timeLastModified"] =
						record.object["timeLastModified"];
				auto fileSpec = JSONValue(fileSpecObject);
				record.object["fileSpecs"] = JSONValue([fileSpec]);
				record.object.remove("fileName");
				record.object.remove("timeLastModified");
			}
			value.object["dataArray"] = JSONValue(records);
		}
		normalizeSingleFileSpecShape(json);
		normalizeSingleFileSpecShape(json0);

		// Tool versions are environment-dependent and are not part of the
		// serialized data contract covered by these fixtures.
		json.object.remove("fileUtilityVersion");
		json.object.remove("mediaInfoVersion");
		json0.object.remove("fileUtilityVersion");
		json0.object.remove("mediaInfoVersion");
		assert(json.object["dataVersion"].integer == DATA_CLASS_VERSION5);
		json.object.remove("dataVersion");
		json0.object.remove("dataVersion");
		assert(json == json0, "Parsed JSON does not match expected JSON.\nGot:\n" ~ json.toString ~ "\nExpected:\n" ~ json0
				.toString);
	}
}

@("(de)serializeDataClassArrayFile 1 - standard fields")
unittest
{
	testSerializeDataClassArrayFile(test_json_v2, 3, json_file_v2);
}

@("(de)serializeDataClassArrayFile 2 - archive serialization")
unittest
{
	import std.file : exists, remove, tempDir;
	import std.path : buildPath;
	import std.uuid : randomUUID;

	const auto fileName = buildPath(tempDir(), "archive-json-v5-"
		~ randomUUID().toString() ~ ".json");
	scope (exit)
		if (exists(fileName))
			remove(fileName);
	fileName.serializeDataClassArrayFile(
		deserializeDataClassJsonString(test_json_v2_archive));
	auto loaded = deserializeDataClassJsonWrapperFile(fileName);
	assert(loaded.dataVersion == DATA_CLASS_VERSION5);
	bool foundArchive;
	bool foundMember;
	string paths;
	foreach (blob; loaded.dataArray)
		foreach (spec; blob.fileSpecs)
		{
			paths ~= "[" ~ spec.fileName ~ "]";
			foundArchive = foundArchive || spec.fileName == "test.rar";
			foundMember = foundMember || spec.fileName == "test.rar!/urtzel.bin";
		}
	assert(foundArchive, paths);
	assert(foundMember, paths);
}

@("(de)serializeDataClassArrayFile 3 - torrentInfo serialization")
unittest
{
	testSerializeDataClassArrayFile(test_json_v2_torrent, 1, json_file_v2_torrent);
}

/** Calc the Digests, if missing
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   gotCtrlC = shared bool pointer to check for Ctrl-C interrupt
 *   progressCallBack = callback function to report progress
 */
void updateDigests(NamedBinaryBlob obj,
	shared(bool)* gotCtrlC = null,
	ProgressCallBack* progressCallBack = null)
{
	auto hasdigests = obj.checkSums.hasDigests;
	if (!hasdigests)
	{

		ubyte[] md, sha, xxh;
		calculatesDigests(gotCtrlC, obj.getFirstExistingFileName, &md, &sha, &xxh, progressCallBack);
		obj.checkSums.set_md5sum = md;
		obj.checkSums.set_sha1sum = sha;
		obj.checkSums.set_xxh64 = xxh;
	}
}

@("updateDigest")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateDigests(dco, null);
	assert(dco.checkSums.hasDigests);
}

/** Query file type text for a blob, if missing.
 *
 * This code is called for a unique binary blob, so using the first existing
 * file entry is sufficient.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if file type already exists
 */
void updateFileType(NamedBinaryBlob obj, bool rescan = false)
{
	if (obj.fileType.empty || rescan)
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			// Find first existing file.
			auto filespecs = obj.getExistingFiles;
			foreach (spec; filespecs)
			{
				import dosierskanilo.metadata.fileutilsig : getFileType;

				obj.fileType = getFileType(spec.fileName);
				break;
			}
		}
	}
}

@("updateFileType")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateFileType(dco, true);
	assert(dco.fileType, "No fileType was set.");
}

/** Get mediaInfo tags for file, if missing
 *
 * This code is called for a unique binary blob. So the MediaInfo MUST be
 * identical.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if MediaInfo already exists
 */
void updateMediaInfo(NamedBinaryBlob obj, bool rescan = false)
{
	if (obj.mediaInfoSig is null || rescan)
	{
		if (obj.fileSize) // Empty files surely have no info at all....
		{
			foreach (spec; obj.getExistingFiles)
			{
				obj.mediaInfoSig = getMediaTypeSignature(spec.fileName);
				break;
			}
		}
	}
}

@("updateMediaInfo")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "images", "sample.bmp");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateMediaInfo(dco, true);
	assert(dco.mediaInfoSig, "No MediaInfo was set.");
}

/** Get the contents of an archive file
 *
 * This code is called for a unique binary blob. So the MediaInfo MUST be
 * identical.
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if info exists
 *   gotCtrlC = shared bool pointer to check for Ctrl-C interrupt
 *   progressCallBack = callback function to report progress
 */
private string archiveCacheIdentity(NamedBinaryBlob blob,
	string physicalPath, string displayPath)
{
	import std.conv : to;

	if (blob.checkSums.hasDigests)
		return "fingerprint:" ~ blob.fileSize.to!string ~ ":"
			~ blob.checkSums.md5sum_b64 ~ ":" ~ blob.checkSums.sha1sum_b64
			~ ":" ~ blob.checkSums.xxh64sum_b64;
	return "path:" ~ (displayPath.length > 0 ? displayPath : physicalPath)
		~ "\0" ~ blob.fileSize.to!string ~ "\0" ~ blob.getFirstFileModDate;
}

void updateArchives(NamedBinaryBlob obj,
	bool rescan = false,
	bool deep = true,
	shared(bool)* gotCtrlC = null,
	ProgressCallBack* progressCallBack = null,
	ArchivePasswordCallback passwordCallback = null,
	size_t depth = 0,
	size_t maxDepth = 8,
	string displayArchivePath = "",
	MemberContentCache memberCache = null,
	bool inspectMemberFileType = false,
	bool inspectMemberMediaInfo = false)
{
	import std.conv : to;
	import core.atomic : atomicLoad;
	import std.file : getSize, getTimes;
	import std.string : format;

	if (memberCache is null)
		memberCache = sharedMemberContentCache();

	if (obj.archiveSpecs is null || rescan)
	{
		if (rescan)
			obj.archiveSpecs = null;
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; obj.getExistingFiles)
			{
				import std.string : startsWith;
				import std.algorithm.searching : find;

				if (obj.fileType.startsWith("RAR") && obj.fileType.find("EncryptedBlockHeader"))
				{
					logLineVerbose();
					logFLineVerbose(
						"Found RAR archive with encrypted block header, skipping archive scan for file '%s'", spec
							.fileName);
					continue;
				}
				auto archiveObj = fileArchive(spec.fileName);
				if (archiveObj)
				{
					const auto archiveDisplayPath = displayArchivePath.length > 0
						? displayArchivePath : spec.fileName;
					const auto containerCacheKey = archiveCacheIdentity(obj,
						spec.fileName, archiveDisplayPath);
					const auto containerCacheIdentity = archiveCacheIdentity(obj,
						spec.fileName, archiveDisplayPath);
					logLineVerbose();
					logFLineVerbose("Found archive of type '%s'", archiveObj.fileType);
					logFLineVerbose("  with file '%s'", spec.fileName);
					logFLineVerbose("  with size %d", obj.fileSize);
					logFLineVerbose("  with 'file' type '%s'", obj.fileType);

					string password = obj.archivePassword;
                    ArchiveEntryDescriptor[] archiveEntries;
                    bool passwordPrompted;
                    while (true)
                    {
                        try
                        {
                            archiveEntries = archiveObj.getEntryDescriptors(password);
                            enforce(archiveEntries !is null,
                                "Archive handler returned no entry index for "
                                ~ spec.fileName);
                            break;
						}
						catch (ArchivePasswordRequiredException ex)
						{
							requestPassword(ex.msg, archiveDisplayPath,
								passwordCallback, password);
							passwordPrompted = true;
						}
					}
                    if (passwordPrompted)
                        obj.archivePassword = password;
                    logFLine("  with %d entries", archiveEntries.length);
                    obj.archiveSpecs = [];
                    if (progressCallBack !is null)
                        progressCallBack.fp(0, archiveEntries.length);

                    foreach (idx, descriptor; archiveEntries)
                    {
                        const auto arcfile = descriptor.name;
                        logFLineVerbose("  with archive file '%s'", arcfile);

                        size_t arcFileSize;
                        string arcModTimeStr;
                        string extractedPath;
                        string memberFileType;
                        MediaInfoSig memberMediaInfo;
                        MemberContentLease extractionLease;
                        scope (exit)
                            if (extractionLease !is null)
                                extractionLease.release();
                        CheckSums sums = CheckSums();
                        if (descriptor.hasDuplicateName
                            && !archiveObj.supportsEntryOccurrence)
                            logFLineVerbose("Archive adapter cannot select duplicate occurrence %d of '%s'; leaving it without a deep fingerprint.",
                                descriptor.occurrence, descriptor.relativePath);
                        if (!descriptor.hasSafePath || descriptor.isDirectory
                            || (descriptor.hasDuplicateName
                                && !archiveObj.supportsEntryOccurrence))
                        {
                            auto unscannedEntry = new ArchiveSpec(arcfile,
                                arcFileSize, arcModTimeStr, sums);
                            unscannedEntry.entryIndex = idx;
                            unscannedEntry.occurrence = descriptor.occurrence;
                            unscannedEntry.hasIndexIdentity = true;
                            obj.archiveSpecs ~= unscannedEntry;
                            if (progressCallBack !is null)
                                progressCallBack.fp(idx + 1, archiveEntries.length);
                            continue;
                        }

                        if (deep)
                        {
                            bool exOk;
                            bool extractionPasswordPrompted;
                            bool occurrenceNotExtractable;
                            while (true)
                            {
                                try
                                {
                                    const auto occurrence = descriptor.occurrence
                                        .to!string;
                                    const auto fallbackIdentity = containerCacheKey
                                        ~ "!/" ~ descriptor.relativePath ~ "!~" ~ occurrence;
                                    const auto cacheContainer = ReferenceId(
                                        "scanner-container:" ~ containerCacheKey);
                                    const auto cacheEntry = ArchiveEntryId(
                                        "scanner-entry:" ~ descriptor.relativePath
                                        ~ ":" ~ occurrence);
                                    const auto locator = ContentLocator.entry(
                                        cacheContainer, cacheEntry);
                                    extractionLease = memberCache.acquire(locator,
                                        ContentId.init, fallbackIdentity,
                                        descriptor.relativePath,
                                        descriptor.hasSize ? descriptor.size : 0,
                                        (string destinationDirectory) {
                                            if (gotCtrlC !is null
                                                && atomicLoad(*gotCtrlC))
                                                return false;
                                            return archiveObj.extractEntry(descriptor,
                                                destinationDirectory, password);
                                        }, gotCtrlC);
                                    exOk = extractionLease !is null;
                                    extractedPath = extractionLease.path;
                                    break;
                                }
                                catch (ArchivePasswordRequiredException ex)
                                {
                                    requestPassword(ex.msg, archiveDisplayPath,
                                        passwordCallback, password);
                                    extractionPasswordPrompted = true;
                                }
                                catch (MemberContentNotExtractableException failure)
                                {
                                    if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                        throw new Exception("Archive scan was cancelled.");
                                    if (!descriptor.hasDuplicateName)
                                        throw failure;
                                    occurrenceNotExtractable = true;
                                    break;
                                }
                            }
                            if (extractionPasswordPrompted)
                                obj.archivePassword = password;
                            if (occurrenceNotExtractable)
                            {
                                logFLineVerbose("Archive adapter could not select duplicate occurrence %d of '%s'; leaving it without a deep fingerprint.",
                                    descriptor.occurrence, descriptor.relativePath);
                                auto unscannedEntry = new ArchiveSpec(arcfile,
                                    arcFileSize, arcModTimeStr, sums);
                                unscannedEntry.entryIndex = idx;
                                unscannedEntry.occurrence = descriptor.occurrence;
                                unscannedEntry.hasIndexIdentity = true;
                                obj.archiveSpecs ~= unscannedEntry;
                                if (progressCallBack !is null)
                                    progressCallBack.fp(idx + 1,
                                        archiveEntries.length);
                                continue;
                            }
                            enforce(exOk, "Failed to extract archive entry '%s' from archive '%s'".format(arcfile,
                                spec.fileName));

                            import dosierskanilo.metadata.digests;
                            ubyte[] md5sum_s, sha1sum_s, xxh64sum_s;
                            calculatesDigests(gotCtrlC, extractedPath,
                                &md5sum_s, &sha1sum_s, &xxh64sum_s,
                                progressCallBack);
                            if (progressCallBack !is null)
                                progressCallBack.fp(idx, archiveEntries.length);

                            sums.set_md5sum = md5sum_s;
                            sums.set_sha1sum = sha1sum_s;
                            sums.set_xxh64 = xxh64sum_s;

                            SysTime arcAccessTime;
                            SysTime arcModTime;
                            extractedPath.getTimes(arcAccessTime, arcModTime);
                            arcModTimeStr = arcModTime.toISOExtString;
                            arcFileSize = extractedPath.getSize;
                            auto extractedBlob = new NamedBinaryBlob(
                                [new FileSpec(extractedPath, arcModTimeStr)],
                                arcFileSize);
                            extractedBlob.checkSums = sums;
                            if (inspectMemberFileType)
                                try
                                    updateFileType(extractedBlob, true);
                                catch (Exception failure)
                                    logFLineVerbose("Could not detect file type for archive member '%s': %s",
                                        arcfile, failure.msg);
                            if (inspectMemberMediaInfo)
                                try
                                    updateMediaInfo(extractedBlob, true);
                                catch (Exception failure)
                                    logFLineVerbose("Could not extract MediaInfo for archive member '%s': %s",
                                        arcfile, failure.msg);
                            memberFileType = extractedBlob.fileType;
                            memberMediaInfo = extractedBlob.mediaInfoSig;
                        }
                        ArchiveSpec[] nestedEntries;
                        string nestedPassword;
                        if (deep && depth < maxDepth && extractedPath.length > 0)
                        {
                            auto nestedArchive = fileArchive(extractedPath);
                            if (nestedArchive !is null)
                            {
                                auto nestedBlob = new NamedBinaryBlob();
                                nestedBlob.fileSize = arcFileSize;
                                nestedBlob.checkSums = sums;
                                nestedBlob.fileSpecs = [new FileSpec(extractedPath,
                                    arcModTimeStr)];
                                const auto nestedDisplayPath = appendArchiveVirtualPath(
                                    archiveDisplayPath, descriptor.relativePath,
                                    descriptor.occurrence > 0
                                        ? descriptor.occurrence : size_t.max);
                                updateArchives(nestedBlob, true, deep, gotCtrlC,
                                    progressCallBack, passwordCallback, depth + 1,
                                    maxDepth, nestedDisplayPath, memberCache,
                                    inspectMemberFileType, inspectMemberMediaInfo);
                                nestedEntries = nestedBlob.archiveSpecs;
                                nestedPassword = nestedBlob.archivePassword;
                            }
                        }
                        auto aspec = new ArchiveSpec(arcfile, arcFileSize,
                            arcModTimeStr, sums);
                        aspec.entryIndex = idx;
                        aspec.occurrence = descriptor.occurrence;
                        aspec.hasIndexIdentity = true;
                        aspec.nestedEntries = nestedEntries;
                        aspec.archivePassword = nestedPassword;
                        aspec.fileType = memberFileType;
                        if (memberMediaInfo !is null)
                            aspec.mediaInfoSig = memberMediaInfo.dup;
                        obj.archiveSpecs ~= aspec;

                        if (progressCallBack !is null)
                            progressCallBack.fp(idx + 1, archiveEntries.length);
					}
					break;
				}
			}
		}
	}
}

private void requestPassword(string reason, string archivePath,
	ArchivePasswordCallback callback, ref string password)
{
	if (callback is null)
		throw new ArchivePasswordRequiredException(
			"Archive password is required for '" ~ archivePath ~ "': " ~ reason);
	string suppliedPassword;
	if (!callback(archivePath, reason, suppliedPassword))
		throw new ArchivePasswordCancelledException(
			"Archive password request was cancelled for '" ~ archivePath ~ "'.");
	password = suppliedPassword;
}

@("updateArchives")
unittest
{
	import std.stdio;
	import std.file; // : exists, remove, write, mkdirRecurse, rmdirRecurse;
	import std.process;
	import std.conv : to;
	import std.string : format;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateArchives(dco, true);
	assert(dco.archiveSpecs.length == 0);

	enum string fnMany = "updateTest-many.zip";
	enum string stagingDir = ".test/updateArchives-many-entries";

	/* Delete the archive with many entries, and the staging directory, if they exist.
	*/
	void deleteManyEntriesArchive()
	{
		if (fnMany.exists)
			std.file.remove(fnMany);
		if (stagingDir.exists)
			rmdirRecurse(stagingDir);
	}

	/* Create an archive with more than 10 entries, to test the code path for that.
	 * The code should scan all entries, not just the first 10.
	 */
	void createManyEntriesArchive(size_t entryCount)
	{
		deleteManyEntriesArchive();
		mkdirRecurse(stagingDir);

		foreach (idx; 0 .. entryCount)
		{
			auto fileName = buildPath(stagingDir, format("entry-%02d.txt", idx));
			std.file.write(fileName, "archive entry " ~ idx.to!string);
		}

		auto rc = executeShell("zip -q \"%s\" %s/*".format(fnMany, stagingDir));
		write(rc.output);
		assert(rc.status == 0, rc.output);
	}

	auto archivePath = buildPath(fixture.catalogRoot, "archives", "sample.zip");
	auto fh1 = File(archivePath);
	auto dco1 = new NamedBinaryBlob(archivePath, fh1.size, SysTime(4_237_892));
	updateArchives(dco1, true);
	assert(dco1.archiveSpecs.length > 0);
	assert(dco1.archiveSpecs.length == 7);
	foreach (entry; dco1.archiveSpecs)
		assert(entry.checkSums.hasDigests,
			"deep archive scans calculate each generated entry checksum");
	auto firstScanEntries = dco1.archiveSpecs.length;
	updateArchives(dco1, true);
	assert(dco1.archiveSpecs.length == firstScanEntries,
		"rescan replaces the entry index instead of appending duplicates");

	createManyEntriesArchive(11);
	scope (success)
		deleteManyEntriesArchive();

	auto fh2 = File(fnMany);
	auto dco2 = new NamedBinaryBlob(fnMany, fh2.size, SysTime(4_237_892));
	updateArchives(dco2, true);
	assert(dco2.archiveSpecs.length >= 11,
		"Expected all archive entries to be scanned for archives with more than 10 files.\nGot %d entries.".format(
			dco2.archiveSpecs.length));
}

@("updateArchives requests and retains encrypted ZIP passwords")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : execute, Config;
	import std.uuid : randomUUID;
	import dosierarkivo.archive : ArchivePasswordCallback;
	import dosierskanilo.membercontentcache : MemberContentCache;

	auto root = buildPath(tempDir(), "dosierskanilo-encrypted-archive-"
		~ randomUUID().toString());
	mkdirRecurse(root);
	scope (exit)
	{
		if (exists(root))
			rmdirRecurse(root);
	}

	write(buildPath(root, "payload.txt"), "encrypted archive payload\n");
	auto archivePath = buildPath(root, "private.zip");
	auto create = execute(["zip", "-q", "-P", "archive-secret", "private.zip",
		"payload.txt"], null, Config.none, size_t.max, root);
	assert(create.status == 0, create.output);

	auto blob = new NamedBinaryBlob(archivePath, archivePath.getSize,
		SysTime(1_234_567));
	size_t prompts;
	ArchivePasswordCallback callback = (string requestedPath, string reason,
		out string password) {
		assert(requestedPath == archivePath);
		assert(reason.length > 0);
		++prompts;
		password = "archive-secret";
		return true;
	};
	auto successfulCache = new MemberContentCache(buildPath(root, "cache-success"));
	updateArchives(blob, true, true, null, null, callback, 0, 8, "",
		successfulCache);
	successfulCache.close();
	assert(prompts == 1);
	assert(blob.archivePassword == "archive-secret");
	assert(blob.archiveSpecs.length == 1);
	assert(blob.archiveSpecs[0].fileName == "payload.txt");

	import std.exception : assertThrown;
	auto rejectedBlob = new NamedBinaryBlob(archivePath, archivePath.getSize,
		SysTime(1_234_567));
	size_t rejectedPrompts;
	ArchivePasswordCallback rejectWrongPassword = (string requestedPath,
		string reason, out string password) {
		++rejectedPrompts;
		if (rejectedPrompts == 1)
		{
			password = "wrong-password";
			return true;
		}
		return false;
	};
	auto rejectedCache = new MemberContentCache(buildPath(root, "cache-rejected"));
	assertThrown!ArchivePasswordCancelledException(updateArchives(rejectedBlob,
		true, true, null, null, rejectWrongPassword, 0, 8, "", rejectedCache));
	rejectedCache.close();
	assert(rejectedPrompts == 2);
	assert(rejectedBlob.archivePassword.length == 0,
		"a cancelled wrong-password attempt must not be persisted");
}

@("deep archive scan fingerprints selectable duplicate occurrences")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : execute, executeShell;
	import std.uuid : randomUUID;

	if (executeShell("command -v python3").status != 0)
		return;
	const auto root = buildPath(tempDir(), "archive-cache-duplicate-scan-"
		~ randomUUID().toString());
	const auto archivePath = buildPath(root, "duplicate.zip");
	mkdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	const auto createScript = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); "
		~ "z.writestr('same.txt', 'first occurrence'); "
		~ "z.writestr('same.txt', 'second occurrence'); z.close()";
	const auto created = execute(["python3", "-c", createScript, archivePath]);
	assert(created.status == 0, created.output);
	auto blob = new NamedBinaryBlob();
	blob.fileSize = cast(size_t) getSize(archivePath);
	blob.fileSpecs = [new FileSpec(archivePath, "")];
	auto cache = new MemberContentCache(buildPath(root, "cache"));
	scope (exit)
		cache.close();
	updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);
	assert(blob.archiveSpecs.length == 2);
	assert(blob.archiveSpecs[0].occurrence == 0);
	assert(blob.archiveSpecs[1].occurrence == 1);
	assert(blob.archiveSpecs[0].checkSums.hasDigests);
	assert(blob.archiveSpecs[1].checkSums.hasDigests);
}

/** Get torrent info for file, if missing
 *
 * Params:
 *   obj = NamedBinaryBlob object to update
 *   rescan = force rescan even if info exists
 */
void updateTorrentInfo(NamedBinaryBlob obj, bool rescan = false)
{
	// Get all existing .torrent files for a bin
	auto torrentFiles =
		obj.getExistingFiles.filter!(a => a.fileName.endsWith(".torrent")).array;
	if (torrentFiles.length == 0)
		return;

	if (obj.torrentInfo is null || rescan)
	{
		import std.algorithm.sorting : sort;
		import std.file : exists;

		if (obj.fileSize) // Empty files surely have no info at all....
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; filespecs)
			{
				try
				{
					obj.torrentInfo = getTorrentInfo(spec.fileName);
				}
				catch (Exception e)
				{
					logFLine("\nCannot analyse torrent: %s", e.msg);
				}
				break;
			}
		}
	}
}

@("updateTorrentInfo")
unittest
{
	import std.stdio : File;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "torrent", "single-file.torrent");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateTorrentInfo(dco, true);
	assert(dco.torrentInfo, "No TorrentInfo was set.");
	assert(dco.torrentInfo.isMultiFile == false);

	string filename2 = buildPath(fixture.catalogRoot, "torrent", "multi-file.torrent");
	auto fh2 = File(filename2);
	auto dco2 = new NamedBinaryBlob(filename2, fh2.size, SysTime(4_237_892));
	updateTorrentInfo(dco2, true);
	assert(dco2.torrentInfo, "No TorrentInfo was set.");
	assert(dco2.torrentInfo.isMultiFile == true);

}

/** Merge identical binblobs into a new combined object
 *
 * objs - list of identical(!) objects
 */
NamedBinaryBlob mergeDataClassObjects(NamedBinaryBlob[] objs)
{
	import std.algorithm.iteration : uniq;
	import std.string : format;

	enforce(objs.length >= 2, "Need at least 2 objects");
	MediaInfoSig mis = null;
	assert(objs.filter!(a => a.checkSums.hasDigests).array.length, "Missing checksums?");

	foreach (obj; objs[1 .. $])
	{
		enforce(objs[0] == obj, "Objects not identical.\n%s\n%s\n"
				.format(objs[0].toString, obj.toString));
		if (!mis)
			mis = obj.mediaInfoSig;
		else
			enforce(mis == obj.mediaInfoSig, "Mismatching MediaInfoSig");
	}

	auto newobj = (objs[0]).dup;
	newobj.mediaInfoSig = mis;
	foreach (o; objs[1 .. $])
		newobj.fileSpecs ~= o.fileSpecs;
	newobj.fileSpecs = newobj.fileSpecs.uniq!("a.fileName == b.fileName", FileSpec[]).array;
	return newobj;
}

/** Set invalidate flag on a range of blobs
 *
 * Params:
 *   objs = Set of objects to invalidate
 */
void invalidateDataClassObjs(NamedBinaryBlob[] objs)
{
	foreach (o; objs)
		o.fileSpecs = [];
}

/** Remove orphaned records whose filesystem references are all unavailable.
 *
 * Params:
 *   objs = Records to filter.
 * Returns: Records with at least one existing file reference. Use only when the
 *     caller explicitly intends missing-file cleanup.
 */
NamedBinaryBlob[] cleanupDataClassObjs(NamedBinaryBlob[] objs)
{
	import std.array;
	import std.algorithm : filter;

	alias matcher = (a) => !a.isBlobOrphaned;
	auto valobjs = objs.filter!(matcher);
	return valobjs.array;
}

/** Remove only records explicitly invalidated by duplicate merging.
 *
 * Unlike `cleanupDataClassObjs`, this helper does not test filesystem
 * existence. Callers can preserve unavailable source references unless the
 * user explicitly requested missing-file removal.
 */
NamedBinaryBlob[] cleanupInvalidatedDataClassObjs(NamedBinaryBlob[] objs)
{
	import std.array : array;
	import std.algorithm : filter;

	return objs.filter!(blob => blob !is null && blob.fileSpecs.length > 0).array;
}

/** Combined unit test for merge operaton
 *
 *
 */
@("mergeDataClassObjects and misc")
unittest
{
	import std.stdio : File;

	string[] filenames = [
		"test/dummy-subtitle-file.srt", "test/dummy-subtitle-file-copy.srt"
	];

	// Create 2 blobs
	auto fh = File(filenames[0]);
	auto dco1 = new NamedBinaryBlob(filenames[0], fh.size, SysTime(4_237_892));
	updateDigests(dco1, null);
	updateMediaInfo(dco1);
	updateFileType(dco1);
	auto dco2 = new NamedBinaryBlob(filenames[1], fh.size, SysTime(8_237_892));
	updateDigests(dco2, null);
	updateMediaInfo(dco2);
	updateFileType(dco2);

	// Merge objs
	auto dcobjs1 = [dco1, dco2];
	auto mdco = mergeDataClassObjects(dcobjs1);
	assert(mdco);
	assert(mdco.mediaInfoSig);
	assert(mdco.fileSpecs.length == 2);

	// Test fixups for (de)serialisation
	auto dcobjs2 = fixupDataClassArrayOut(dcobjs1);
	auto dcobjs3 = fixupDataClassArrayIn(dcobjs2);

	// test deletion of nodes from array
	invalidateDataClassObjs(dcobjs3);
	auto dcobj4 = cleanupDataClassObjs(dcobjs3);
	assert(dcobj4.length == 0);
}
