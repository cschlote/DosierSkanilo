/** Calculate digests and suport code
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module dosierskanilo.digests;

import std.digest.md;
import std.digest.sha;
import std.stdio;

import xxhash3;

// FIXME: Move this to more general place.
import commandline : ProgressCallBack;

/** Calculate the MD5 and SHA1 checksum
 *
 * Just read the binary data *once* per file and feed it to all checksummers.
 *
 * Params:
 *  gotCtrlC = pointer to bool. Set to true, when control-c was hit
 *  fileName = name of file to checksum, file must exist!
 *  md5sum = a md5sum as binary array
 *  sha1sum = a sha1 as binary array
 *  xxh64sum = a XXH64 checksum
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
		if (progressCallBack)
			progressCallBack.fp(pos, msz);

		if (md5sum !is null)
			md5.put(buffer);
		if (sha1sum !is null)
			sha1.put(buffer);
		if (xxh64sum !is null)
			xxh64.put(buffer);

		if (gotCtrlC !is null && *gotCtrlC)
			return;

		pos += buffSize;
	}
	if (md5sum !is null)
		*md5sum = md5.finish();
	if (sha1sum !is null)
		*sha1sum = sha1.finish().dup;
	if (xxh64sum !is null)
		*xxh64sum = xxh64.finish().dup;

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
