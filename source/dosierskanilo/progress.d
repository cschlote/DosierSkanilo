/** Progress callback types shared with scanner jobs.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.progress;

import std.array : array;
import std.conv : text, to;
import std.datetime : Clock, Duration, SysTime, dur;
import std.format : format;
import std.range : cycle, take;
import std.stdio : write;
import std.string : empty, startsWith;

import dosierskanilo.logging;

/** Wrapper around a progress callback function pointer. */
struct ProgressCallBack
{
	void function(size_t i, size_t m) fp;
}

dstring shortenMiddle(string str, size_t maxLen)
{
	auto dstr = str.to!dstring;
	if (dstr.length <= maxLen)
		return dstr;

	auto ellipsis = "..."d;
	enum ellipsisLen = 3;
	if (maxLen <= ellipsisLen)
		return dstr[0 .. maxLen];

	auto remain = maxLen - ellipsisLen;
	auto headLen = remain / 2 + (remain % 2);
	auto tailLen = remain - headLen;

	auto head = dstr[0 .. headLen];
	auto tail = dstr[$ - tailLen .. $];

	return head ~ ellipsis ~ tail;
}

@("shortenMiddle")
unittest
{
	auto type0 = shortenMiddle("123456", 3);
	assert(type0 == "123"d, type0.to!string);

	auto str1 = "test/dummy-text-file.txt";
	auto type1 = shortenMiddle(str1, 60);
	assert(type1 == str1.to!dstring, type1.to!string);
	assert(type1.length == str1.length, type1.to!string);

	auto str2 = "test/test2/test3/test4/very-long-dummy-very-long-audio-file.mp3";
	auto type2 = shortenMiddle(str2, 60);
	auto str2a = "test/test2/test3/test4/very-l...mmy-very-long-audio-file.mp3"d;
	assert(type2 == str2a, type2.to!string);
	assert(type2.length == 60, type2.to!string);

	auto type3 = shortenMiddle(`さいごの果実 / ミツバチと科学者`, 10);
	assert(type3 == "さいごの...科学者"d, type3.to!string);
	assert(type3.length == 10, type3.to!string);

	auto type4 = shortenMiddle("|aaaa|bbbb|cccc|dddd|eeee|ffff|gggg|hhhh", 15);
	assert(type4.length == 15, type4.to!string);
	assert(type4 == "|aaaa|...g|hhhh", type4.to!string);
}

dstring padLeft(dstring s, size_t padlen)
{
	size_t slen = s.length;
	if (slen > padlen)
		return s;

	size_t plen = padlen - slen;
	auto pad = " ".cycle.take(plen).array.to!dstring;
	return pad ~ s;
}

unittest
{
	dstring a = "!--- !--- !--- ";
	dstring a1 = padLeft(a, 10);
	assert(a == a1, a1.to!string);

	dstring a2 = padLeft(a, 15);
	assert(a == a2, a2.to!string);

	dstring a3 = padLeft(a, 20);
	dstring b3 = "     !--- !--- !--- "d;
	assert(b3 == a3, a3.to!string);
}

string makeProgressString(size_t i, size_t m)
{
	static int q = 0;
	char[] p = ['-', '\\', '|', '/', '-', '|', '/', '-'];
	auto result = format("%c %.6f", p[q++], (i.to!float / m.to!float));
	q &= 0x7;
	return result;
}

@("makeProgressString")
unittest
{
	auto s1 = makeProgressString(0, 100);
	assert(s1.startsWith("- 0.000000"), s1);
	auto s2 = makeProgressString(50, 100);
	assert(s2.startsWith("\\ 0.500000"), s2);
	auto s3 = makeProgressString(100, 100);
	assert(s3.startsWith("| 1.000000"), s3);
}

SysTime lastProgress;
size_t lastIdx;
size_t lastTotalFiles;
string lastFile;

void progressCallBack(size_t i, size_t m)
{
	printProgress(lastIdx, lastTotalFiles, lastFile, makeProgressString(i, m));
}

void printProgress(size_t idx, size_t totalfiles, string file, string subJob = null)
{
	enum EL0 = "\x1b[K";

	lastIdx = idx;
	lastTotalFiles = totalfiles;
	lastFile = file;

	if (file.empty || idx == 0)
	{
		lastProgress = Clock.currTime;
	}
	Duration lastDelta = Clock.currTime - lastProgress;
	bool itsTime = lastDelta > dur!"seconds"(1);
	if (file.empty || idx == 0 || itsTime)
	{
		enum fnfsz = 66;
		auto fileEclipsed = shortenMiddle(file, fnfsz);
		assert(fileEclipsed.length <= fnfsz, "clip: " ~ fileEclipsed.length.text);
		fileEclipsed = padLeft(fileEclipsed, fnfsz);
		try
		{
			logF("\r%6d/%6d:%10s:%s" ~ EL0, idx, totalfiles, subJob, fileEclipsed[$ - fnfsz .. $]);
		}
		catch (Exception ex)
		{
			logLine("\n");
			logFLine("Catched exception: %s\nFile: %s", ex.msg, file);
		}
		lastProgress = Clock.currTime;
	}
}

@("printProgress")
unittest
{
	printProgress(0, 1000, "test/dummy-text-file.txt");
	printProgress(1, 1000, "test/dummy-text-file.txt");
	printProgress(10, 1000, "test/dummy-text-file.txt");
	printProgress(100, 1000, "test/dummy-text-file.txt");
	printProgress(1000, 1000, "test/dummy-text-file.txt");
	logLine("");
}
