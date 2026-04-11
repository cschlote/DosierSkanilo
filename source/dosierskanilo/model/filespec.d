/** Data class for filenames associated with a binary blob
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.model.filespec;

import jsonizer;

import std.format : format;
import std.datetime : SysTime;

/** Each binary blob can have multiple filenames and times */
class FileSpec
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		string fileName;
		string timeLastModified;
	}

	this()
	{
		fileName = "";
		timeLastModified = "";
	}

	this(string fn, string modtime) @safe
	{
		fileName = fn;
		timeLastModified = modtime;
	}

	this(string fn, SysTime modtime)
	{
		fileName = fn;
		timeLastModified = modtime.toISOExtString;
	}

	int opCmp(FileSpec rhs) const pure @safe
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
		return format("FileSpec('%s', %s)", fileName, timeLastModified);
	}

	// int opEquals(FileSpec rhs) const pure
	// {
	// 	return this.fileName == rhs.fileName &&
	// 		this.timeLastModified == rhs.timeLastModified;
	// }

	import std.typecons : Nullable;

	private Nullable!bool fileExists; ///< Helper field, not serialized

	/** Check if the file exists on disk
	 *
	 * Returns: true, if the file exists on disk, false otherwise
	 * Note: The result is cached in the fileExists field to avoid multiple disk accesses for the same file.
	 */
	bool exists() @safe
	{
		import std.file : exists;

		if (this.fileExists.isNull)
		{
			this.fileExists = this.fileName.exists;
		}
		return this.fileExists.get;
	}
}

@("class FileSpec")
unittest
{
    import std.datetime.systime : SysTime;

	auto ts = SysTime(1_234_567).toISOExtString;

	auto fs0 = new FileSpec();
	assert(fs0.fileName == "");
	assert(fs0.timeLastModified == "");
	assert(fs0.toString == `FileSpec('', )`, fs0.toString);

	auto fs1 = new FileSpec("test/dummy-text-file.txt", SysTime(1_234_567));
	assert(fs1.toString == format("FileSpec('%s', %s)", "test/dummy-text-file.txt", ts), fs1
			.toString);
	assert(fs1.exists, "File must exist");

	auto fs2 = new FileSpec("test/non-existing-file.txt", SysTime(1_234_567));
	assert(!fs2.exists, "File must not exist");

	assert(fs1.opCmp(fs2) < 0, "fs1 < fs2");
	assert(fs2.opCmp(fs1) > 0, "fs2 > fs1");
	assert(fs1.opCmp(fs1) == 0, "fs1 == fs1");
}
