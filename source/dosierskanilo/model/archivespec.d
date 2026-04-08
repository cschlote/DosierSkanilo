/** Data class for a file inside an archive
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.model.archivespec;

import jsonizer;

public import dosierskanilo.model.checksums;

import std.format : format;

/** Contents description of an archive file
 *
 * There are several known archive file formats (zip, tar, rar, 7z, ...). Each of
 * them can contain multiple files inside. We store the basic information
 * about each file inside the archive in this class.
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

	this()
	{
		fileName = "";
		fileSize = 0;
		timeLastModified = "";
		checkSums = CheckSums();
	}

	this(string fn, size_t fsize, string modtime, CheckSums sums)
	{
		fileName = fn;
		fileSize = fsize;
		timeLastModified = modtime;
		checkSums = sums;
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
	auto asd0 = as0.toString;
	// writeln("AS0: ", asd0);
	assert(asd0 == `ArchiveSpec('', 0, '', const(CheckSums)("", "", ""))`, as0.toString);

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
