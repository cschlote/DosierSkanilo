/** Data class for the checksums of a file
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.checksums;

import jsonizer;

import std.base64 : Base64;
import std.string : empty;

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

	/** the file md5sum as a property
	 *
	 * Returns: Decoded MD5 digest bytes, or `null` when no digest is stored.
	 */
	ubyte[] get_md5sum() const @property pure @safe
	{
		return (md5sum_b64 is null) ? null : Base64.decode(md5sum_b64);
	}

	/** setter - the file md5sum as a property
	 *
	 * Params:
	 *     data = Raw MD5 digest bytes; `null` clears the stored digest.
	 */
	void set_md5sum(ubyte[] data) @property @safe
	{
		md5sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file sha1sum as a property
	 *
	 * Returns: Decoded SHA-1 digest bytes, or `null` when no digest is stored.
	 */
	ubyte[] get_sha1sum() const @property pure @safe
	{
		return (sha1sum_b64 is null) ? null : Base64.decode(sha1sum_b64);
	}

	/** setter - the file sha1sum as a property
	 *
	 * Params:
	 *     data = Raw SHA-1 digest bytes; `null` clears the stored digest.
	 */
	void set_sha1sum(ubyte[] data) @property @safe
	{
		sha1sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** getter - the file xxh64 as a property
	 *
	 * Returns: Decoded xxh64 digest bytes, or `null` when no digest is stored.
	 */
	ubyte[] get_xxh64() const @property pure @safe
	{
		return (xxh64sum_b64 is null) ? null : Base64.decode(xxh64sum_b64);
	}

	/** setter - the file xxh64 as a property
	 *
	 * Params:
	 *     data = Raw xxh64 digest bytes; `null` clears the stored digest.
	 */
	void set_xxh64(ubyte[] data) @property @safe
	{
		xxh64sum_b64 = (data is null) ? null : Base64.encode(data);
	}

	/** Check if all three digests are present.
	 *
	 * Returns: `true` when the MD5, SHA-1, and xxh64 base64 strings are all
	 *     non-empty.
	 */
	bool hasDigests() @safe pure nothrow const
	{
		return !this.md5sum_b64.empty && !this.sha1sum_b64.empty && !this.xxh64sum_b64.empty;
	}

	/** equality operator
	 *
	 * Two checksums are equal only when both have all three digests and their
	 * encoded digest strings match.
	 *
	 * Params:
	 *     other = Checksums to compare with.
	 * Returns: `true` when both objects carry the same complete digest set.
	 */
	bool opEquals(const CheckSums other) const @safe
	{
		return this.hasDigests && other.hasDigests &&
			this.md5sum_b64 == other.md5sum_b64 &&
			this.sha1sum_b64 == other.sha1sum_b64 &&
			this.xxh64sum_b64 == other.xxh64sum_b64;
	}

	/** Compute a hash over the encoded digest strings for use in hash containers.
	 *
	 * The hash covers the base64 text of the MD5, SHA-1 and xxh64 digests in
	 * that order.
	 *
	 * Returns: A deterministic `size_t` hash, or `0` when any digest is
	 *     missing (see `hasDigests`).
	 */
	size_t toHash() const nothrow @safe
	{
		if (!this.hasDigests)
			return 0;

		size_t hash = 14695981039346656037UL;
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

	assert(!sums.hasDigests, "Empty sums must not report digests.");
	assert(sums.toHash == 0, "Empty sums must hash to zero.");

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

	sums2.set_xxh64([7, 6, 5, 4, 3, 2, 1]);
	assert(sums != sums2, "Partial mismatch should break equality.");
}
