/** Data class for the checksums of a file
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.model.checksums;

import jsonizer;

import std.base64 : Base64;
import std.string :  empty;

/** Simple struct to store the checksums of a file
 *
 * This struct encapsulates the checksums of a file in base64 encoding.
 */
struct CheckSums
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		string md5sum_b64; ///< base64 of md5 hash
		string sha1sum_b64; ///< base 64 of sha1 hash
		string xxh64sum_b64; ///< base 64 of xxh64 hash
	}

	/** the file md5sum as a property */
	ubyte[] get_md5sum() const @property pure @safe
	{
		return (md5sum_b64 is null) ? null : Base64.decode(md5sum_b64);
	}

	/** setter - the file md5sum as a property */
	void set_md5sum(ubyte[] data) @property @safe
	{
		md5sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file sha1sum as a property */
	ubyte[] get_sha1sum() const @property pure @safe
	{
		return (sha1sum_b64 is null) ? null : Base64.decode(sha1sum_b64);
	}

	/** setter - the file sha1sum as a property */
	void set_sha1sum(ubyte[] data) @property @safe
	{
		sha1sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file xxh64 as a property */
	ubyte[] get_xxh64() const @property pure @safe
	{
		return (xxh64sum_b64 is null) ? null : Base64.decode(xxh64sum_b64);
	}

	/** setter - the file xxh64 as a property */
	void set_xxh64(ubyte[] data) @property @safe
	{
		xxh64sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** Check if all three digests are present */
	bool hasDigests() @safe pure nothrow const
	{
		return !this.md5sum_b64.empty && !this.sha1sum_b64.empty && !this.xxh64sum_b64.empty;
	}

	/** equality operator
	*/
	bool opEquals(const CheckSums other) const @safe
	{
		return this.hasDigests && other.hasDigests &&
			this.md5sum_b64 == other.md5sum_b64 &&
			this.sha1sum_b64 == other.sha1sum_b64 &&
			this.xxh64sum_b64 == other.xxh64sum_b64;
	}

	size_t toHash() const nothrow @safe
	{
		if (!this.hasDigests)
			return 0;

		size_t hash = 1469598103934665603UL;
		void mixString(string value) nothrow @safe
		{
			foreach (immutable char ch; value)
			{
				hash ^= cast(ubyte) ch;
				hash *= 1099511628211UL;
			}
			hash ^= 0xff;
			hash *= 1099511628211UL;
		}

		mixString(this.md5sum_b64);
		mixString(this.sha1sum_b64);
		mixString(this.xxh64sum_b64);
		return hash;
	}
}

@("struct CheckSums")
unittest
{
	CheckSums sums;
	ubyte[] testdata = [1, 2, 3, 4, 5, 6, 7];

	sums.set_md5sum(testdata);
	assert(sums.get_md5sum == testdata, "Data Mismatch");
	assert(!sums.hasDigests, "Check failed.");

	sums.set_sha1sum(testdata);
	assert(sums.get_sha1sum == testdata, "Data Mismatch");
	assert(!sums.hasDigests, "Check failed.");

	sums.set_xxh64(testdata);
	assert(sums.get_xxh64 == testdata, "Data Mismatch");
	assert(sums.hasDigests, "Check failed.");

	CheckSums sums2;
	sums2.set_md5sum(testdata);
	sums2.set_sha1sum(testdata);
	sums2.set_xxh64(testdata);
	assert(sums == sums2, "Equality mismatch");
	assert(sums.toHash == sums2.toHash, "Hash mismatch");
}
