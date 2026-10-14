/** Legacy nested metadata for one member listed inside an archive.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.archivespec;

import jsonizer;

public import dosierskanilo.model.checksums;

import std.format : format;

/** Basic contents description nested under the archive's `NamedBinaryBlob`.
 *
 * This type stores entry path, size, modification time, and optional checksums.
 * It does not itself have a content-blob identity or source locator; promotion
 * of archive members into the normal catalog model is planned in WP-13.5.
 */
class ArchiveSpec
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize
	{
		string fileName;
		size_t fileSize;
		string timeLastModified;
	}
 @jsonize(JsonizeIn.opt, JsonizeOut.opt)
 CheckSums checkSums;
    /** Version-4 recursive index of this member when it is itself an archive. */
    @jsonize(JsonizeIn.opt, JsonizeOut.opt)
    ArchiveSpec[] nestedEntries;
    /** Version-4 password accepted while indexing a nested archive member. */
    @jsonize(JsonizeIn.opt, JsonizeOut.opt)
    string archivePassword;

    /** Adapter-only identity data; never serialized in JSON catalogs. */
    @jsonize(JsonizeIn.no, JsonizeOut.no)
    {
        size_t entryIndex;
        size_t occurrence;
        bool hasIndexIdentity;
        long contentBlobId;
        string contentIdentity;
    }

	this()
	{
		fileName = "";
		fileSize = 0;
		timeLastModified = "";
		checkSums = CheckSums();
		nestedEntries = null;
		archivePassword = "";
	}

	this(string fn, size_t fsize, string modtime, CheckSums sums)
	{
		fileName = fn;
		fileSize = fsize;
		timeLastModified = modtime;
		checkSums = sums;
		nestedEntries = null;
		archivePassword = "";
	}

	import std.datetime : SysTime;
	import core.stdcpp.array;
	import std.experimental.allocator.building_blocks.fallback_allocator;

	this(string fn, size_t fsize, SysTime modtime, CheckSums sums)
	{
		fileName = fn;
		fileSize = fsize;
		timeLastModified = modtime.toISOExtString;
		checkSums = sums;
		nestedEntries = null;
		archivePassword = "";
	}

	int opCmp(ArchiveSpec rhs) const pure @safe
	{
		if (this.fileName > rhs.fileName)
			return 1;
		else if (this.fileName < rhs.fileName)
			return -1;
		else
			return 0;
	}

	/** Deep-copy this entry, including nested archive member metadata. */
	ArchiveSpec dup() const
	{
		auto result = new ArchiveSpec(fileName, fileSize, timeLastModified,
			checkSums);
		result.archivePassword = archivePassword;
		result.entryIndex = entryIndex;
		result.occurrence = occurrence;
		result.hasIndexIdentity = hasIndexIdentity;
		result.contentBlobId = contentBlobId;
		result.contentIdentity = contentIdentity;
		if (nestedEntries !is null)
		{
			result.nestedEntries = [];
			foreach (entry; nestedEntries)
				result.nestedEntries ~= entry is null ? null : entry.dup();
		}
		return result;
	}

	override string toString() const pure
	{
		return format("ArchiveSpec('%s', %d, '%s', %s)", fileName, fileSize, timeLastModified, checkSums);
	}
}

@("class ArchiveSpec")
unittest
{
    import std.datetime.systime : SysTime;

	auto ts = SysTime(1_234_567).toISOExtString;

	auto as0 = new ArchiveSpec();
	assert(as0.fileName == "");
	assert(as0.fileSize == 0);
	assert(as0.timeLastModified == "");
	auto asd0 = as0.toString;
	// writeln("AS0: ", asd0);
	assert(asd0 == `ArchiveSpec('', 0, '', const(CheckSums)("", "", ""))`, as0.toString);

	auto as0s = new ArchiveSpec("test/dummy-text-file.txt", 1_234_567, ts, CheckSums());
	assert(as0s.fileName == "test/dummy-text-file.txt");
	assert(as0s.fileSize == 1_234_567);
	assert(as0s.timeLastModified == ts);

	auto as1 = new ArchiveSpec("test/dummy-text-file.txt", 1_234_567, SysTime(1_234_567), CheckSums());
	auto asd1 = as1.toString;
	// writeln("AS1: ", asd1);
	assert(
		asd1 == format("ArchiveSpec('%s', %d, '%s', %s)", "test/dummy-text-file.txt", 1_234_567, ts,
			const(CheckSums)()), as1
			.toString);

	assert(as1.opCmp(as0) > 0, "as1 > as0");
	assert(as0.opCmp(as1) < 0, "as0 < as1");
	assert(as1.opCmp(as1) == 0, "as1 == as1");
}
