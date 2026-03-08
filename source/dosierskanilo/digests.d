/** Digest calculation helpers.
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module dosierskanilo.digests;

import std.digest.md;
import std.digest.sha;
import std.file;
import std.path;
import std.stdio;
import std.uuid;

import xxhash3;

// FIXME: Move this to more general place.
import commandline : ProgressCallBack;

/** Calculate MD5, SHA1, and XXH64 digests for a file.
 *
 * Just read the binary data *once* per file and feed it to all checksummers.
 *
 * Params:
 *  gotCtrlC = pointer to stop flag set when Ctrl-C was received
 *  fileName = file path to checksum (must exist)
 *  md5sum = destination MD5 digest as binary array (optional)
 *  sha1sum = destination SHA1 digest as binary array (optional)
 *  xxh64sum = destination XXH64 digest as binary array (optional)
 *  progressCallBack = optional progress callback
 */
void calculatesDigests(
	shared(bool)* gotCtrlC, const string fileName,
	scope ubyte[]* md5sum,
	scope ubyte[]* sha1sum,
	scope ubyte[]* xxh64sum,
	ProgressCallBack* progressCallBack
)
{
	auto md5 = new MD5Digest();
	auto sha1 = new SHA1();
	XXH_64 xxh64;

	if (md5sum !is null)
		md5.reset();
	if (sha1sum !is null)
		sha1.start();
	if (xxh64sum !is null)
		xxh64.start();

	auto fh = File(fileName, "rb");
	size_t msz = fh.size;
	size_t pos = 0;
	enum buffSize = 16 * 1024 * 1024;
	foreach (ubyte[] buffer; chunks(fh, buffSize))
	{
		if (md5sum !is null)
			md5.put(buffer);
		if (sha1sum !is null)
			sha1.put(buffer);
		if (xxh64sum !is null)
			xxh64.put(buffer);

		if (gotCtrlC !is null && *gotCtrlC)
			return;

		pos += buffer.length;
		if (progressCallBack)
			progressCallBack.fp(pos, msz);
	}
	if (md5sum !is null)
		*md5sum = md5.finish();
	if (sha1sum !is null)
		*sha1sum = sha1.finish().dup;
	if (xxh64sum !is null)
		*xxh64sum = xxh64.finish().dup;

}

@("calculatesDigests progress small file")
unittest
{
	static size_t[] progressSeen;
	static void trackProgress(size_t i, size_t m)
	{
		assert(i <= m, "Progress should never exceed file size");
		progressSeen ~= i;
	}

	auto tmpFile = buildPath(tempDir(), "digest-progress-small-" ~ randomUUID().toString() ~ ".bin");
	scope (exit)
	{
		if (exists(tmpFile))
			remove(tmpFile);
	}

	std.file.write(tmpFile, cast(ubyte[])[1, 2, 3, 4, 5]);
	progressSeen.length = 0;
	ProgressCallBack cb;
	cb.fp = &trackProgress;

	ubyte[] md5sum;
	calculatesDigests(null, tmpFile, &md5sum, null, null, &cb);

	assert(progressSeen.length == 1, "Small file should complete in one chunk");
	assert(progressSeen[$ - 1] == 5, "Final progress should match file size");
}

@("calculatesDigests progress non multiple of buffer")
unittest
{
	static size_t[] progressSeen;
	static void trackProgress(size_t i, size_t m)
	{
		assert(i <= m, "Progress should never exceed file size");
		progressSeen ~= i;
	}

	enum testSize = 16 * 1024 * 1024 + 123;
	auto tmpFile = buildPath(tempDir(), "digest-progress-large-" ~ randomUUID().toString() ~ ".bin");
	scope (exit)
	{
		if (exists(tmpFile))
			remove(tmpFile);
	}

	auto payload = new ubyte[testSize];
	foreach (i; 0 .. payload.length)
		payload[i] = cast(ubyte)(i & 0xFF);
	std.file.write(tmpFile, payload);

	progressSeen.length = 0;
	ProgressCallBack cb;
	cb.fp = &trackProgress;

	ubyte[] md5sum;
	calculatesDigests(null, tmpFile, &md5sum, null, null, &cb);

	assert(progressSeen.length == 2, "Expected two chunks for >16 MiB test file");
	assert(progressSeen[0] == 16 * 1024 * 1024, "First chunk should equal buffer size");
	assert(progressSeen[$ - 1] == testSize, "Final progress should match full size");
}

@("calculatesDigests")
unittest
{
	string localFile = "test/dummy-text-file.txt";
	ubyte[] md5sum, sha1sum, xxh64sum;
	md5sum.length = 0;
	sha1sum.length = 0;
	xxh64sum.length = 0;
	calculatesDigests(null, localFile, &md5sum, &sha1sum, &xxh64sum, null);
	// debug { import std.stdio : writeln; try { writeln(md5sum); } catch (Exception) {} }
	// debug { import std.stdio : writeln; try { writeln(sha1sum); } catch (Exception) {} }
	// debug { import std.stdio : writeln; try { writeln(xxh64sum); } catch (Exception) {} }
	assert(md5sum == [
		23, 158, 47, 247, 248, 244, 190, 16, 223, 13, 250, 121, 227, 156, 251, 251
	]);
	assert(sha1sum == [
		192, 217, 35, 117, 206, 142, 239, 239, 88, 68, 190, 231, 231, 183, 233,
		158, 54, 211, 145, 192
	]);
	assert(xxh64sum == [131, 45, 231, 248, 88, 105, 250, 187]);
}
