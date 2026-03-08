/** Media signature extraction using libmediainfo.
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module dosierskanilo.mediainfosig;

import std.array : array;
import std.algorithm : map;
import std.conv;
import std.exception;
import std.file : exists, isDir, isFile, DirEntry, dirEntries, SpanMode;
import std.format;
import std.path : baseName, absolutePath;
import std.range : chain;
import std.stdio;
import std.string;

import jsonizer;

import mediainfodll;
import mediainfo;

import logging;

/** A structure with image media info
 *
 * This class holds information about an image stream.
 */
class MediaInfoImage
{
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		int index; ///< index of the image stream
		string format; ///< format of the image stream
		ulong width; ///< width of the image stream
		ulong height; ///< height of the image stream
	}
public:
	/// default constructor
	this()
	{
		index = 0;
		format = "";
		width = 0;
		height = 0;
	}
	/// constructor with parameters
	@jsonize this(int idx, string fmt, ulong w, ulong h)
	{
		index = idx;
		format = fmt;
		width = w;
		height = h;
	}
	/// create a string from the object contents
	override string toString() const
	{
		string met;
		met = "image%d('%s', %ux%u)"
			.format(index, format, width, height);
		return met;
	}

	MediaInfoImage dup()
	{
		auto mii = new MediaInfoImage(index, format, width, height);
		return mii;
	}
}

@("class MediaInfoImage")
unittest
{
	auto mii1 = new MediaInfoImage();
	assert(mii1.toString == "image0('', 0x0)", mii1.toString);
	auto mii2 = new MediaInfoImage(1, "JPG", 320, 200);
	assert(mii2.toString == "image1('JPG', 320x200)", mii2.toString);

	auto mii3 = mii2.dup;
	assert(&mii3 != &mii2, "No different object");
}

/** A structure with video media info
 * This class holds information about a video stream.
 */
class MediaInfoVideo
{
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		int index; ///< index of the video stream
		string language; ///< language of the video stream
		string format; ///< format of the video stream
		ulong width; ///< width of the video stream
		ulong height; ///< height of the video stream
		double frameRate; ///< frame rate of the video stream
		ulong bitRate; ///< bit rate of the video stream
		string duration; ///< duration of the video stream
	}
	/// default constructor
	this()
	{
		index = 0;
		language = "";
		format = "";
		width = 0;
		height = 0;
		frameRate = 0.0;
		bitRate = 0;
		duration = "";
	}
	/// constructor with parameters
	@jsonize this(int idx, string lang, string fmt, ulong w, ulong h, double fr = 0.0, ulong br = 0, string dur = null)
	{
		index = idx;
		language = lang;
		format = fmt;
		width = w;
		height = h;
		frameRate = fr;
		bitRate = br;
		duration = dur;
	}

	/// create a string from the object contents
	override string toString() const
	{
		string met;
		met = "video%d('%s', '%s', %ux%u, %sfps, %dbps, '%s')"
			.format(index, language, format, width, height, frameRate, bitRate, duration);
		return met;
	}

	/// duplicate object
	MediaInfoVideo dup()
	{
		return new MediaInfoVideo(index, language, format, width, height, frameRate, bitRate, duration);
	}
}

@("class MediaInfoVideo")
unittest
{
	auto miv1 = new MediaInfoVideo();
	assert(miv1.toString == "video0('', '', 0x0, 0fps, 0bps, '')", miv1.toString);
	auto miv2 = new MediaInfoVideo(1, "de", "AV1", 320, 200);
	assert(miv2.toString == "video1('de', 'AV1', 320x200, 0fps, 0bps, '')", miv2.toString);
	auto miv3 = new MediaInfoVideo(1, "de", "AV1", 320, 200, 25.0, 5000 * 1000, "1h");
	assert(miv3.toString == "video1('de', 'AV1', 320x200, 25fps, 5000000bps, '1h')", miv3.toString);
	auto miv9 = miv2.dup;
	assert(&miv9 != &miv2, "No different object");
}

/** A structure with audio media info
 * This class holds information about an audio stream.
 */
class MediaInfoAudio
{
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		int index; ///< index of the audio stream
		string language; ///< language of the audio stream
		string format; ///< format of the audio stream
		ulong channels; ///< number of channels in the audio stream
		ulong bitRate; ///< bit rate of the audio stream
		string duration; ///< duration of the audio stream
	}
	/// default constructor
	this()
	{
		index = 0;
		language = "";
		format = "";
		channels = 0;
		bitRate = 0;
		duration = "";
	}
	/// constructor with parameters
	@jsonize this(int idx, string lang, string fmt, ulong ch, ulong br = 0, string dur = "")
	{
		index = idx;
		language = lang;
		format = fmt;
		channels = ch;
		bitRate = br;
		duration = dur;
	}
	/// create a string from the object contents
	override string toString() const
	{
		string met;
		met = "audio%d('%s', '%s', %u ch., %dbps, '%s')"
			.format(index, language, format, channels, bitRate, duration);
		return met;
	}
	/// duplicate object
	MediaInfoAudio dup()
	{
		return new MediaInfoAudio(index, language, format, channels, bitRate, duration);
	}
}

@("class MediaInfoAudio")
unittest
{
	auto mia1 = new MediaInfoAudio();
	assert(mia1.toString == "audio0('', '', 0 ch., 0bps, '')", mia1.toString);
	auto mia2 = new MediaInfoAudio(1, "de", "AAC", 2);
	assert(mia2.toString == "audio1('de', 'AAC', 2 ch., 0bps, '')", mia2.toString);
	auto mia3 = new MediaInfoAudio(1, "de", "AAC", 6, 200_000, "1h");
	assert(mia3.toString == "audio1('de', 'AAC', 6 ch., 200000bps, '1h')", mia3.toString);
	auto mia9 = mia2.dup;
	assert(&mia9 != &mia2, "No different object");
}

/** A structure for Subtitle media info
 * This class holds information about a text stream.
*/
class MediaInfoText
{
	mixin JsonizeMe;

	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		int index; ///< index of the text stream
		string language; ///< language of the text stream
		string format; ///< format of the text stream
		double frameRate; ///< frame rate of the text stream
		ulong bitRate; ///< bit rate of the text stream
		string duration; ///< duration of the text stream
	}
	/// default constructor
	this()
	{
		index = 0;
		language = "";
		format = "";
		frameRate = 0.0;
		bitRate = 0;
		duration = "";
	}
	/// constructor with parameters
	@jsonize this(int idx, string lang, string fmt, double fr = 0.0, ulong br = 0, string dur = "")
	{
		index = idx;
		language = lang;
		format = fmt;
		frameRate = fr;
		bitRate = br;
		duration = dur;
	}
	/// create a string from the object contents
	override string toString() const
	{
		string met;
		met = "text%d('%s', '%s', %sfps, %dbps, '%s')"
			.format(index, language, format, frameRate, bitRate, duration);
		return met;
	}
	/// duplicate
	MediaInfoText dup()
	{
		return new MediaInfoText(index, language, format, frameRate, bitRate, duration);
	}

}

@("class MediaInfoText")
unittest
{
	auto mit1 = new MediaInfoText();
	assert(mit1.toString == "text0('', '', 0fps, 0bps, '')", mit1.toString);
	auto mit2 = new MediaInfoText(1, "de", "AAC");
	assert(mit2.toString == "text1('de', 'AAC', 0fps, 0bps, '')", mit2.toString);
	auto mit3 = new MediaInfoText(1, "de", "AAC", 0.10, 200_000, "1h");
	assert(mit3.toString == "text1('de', 'AAC', 0.1fps, 200000bps, '1h')", mit3.toString);

	auto mit9 = mit2.dup;
	assert(&mit9 != &mit2, "No different object");
}

/**
 * A structure with data class info
 * This class holds information about all media streams.
 */
class MediaInfoSig
{
	/* Add code needed for JSON serialization */
	mixin JsonizeMe;

	/* public serialized members */
	@jsonize(JsonizeIn.opt, JsonizeOut.opt)
	{
		MediaInfoImage[] imageStreams; ///< array of image streams
		MediaInfoVideo[] videoStreams; ///< array of video streams
		MediaInfoAudio[] audioStreams; ///< array of audio streams
		MediaInfoText[] textStreams; ///< array of text streams
	}
	/// default constructor
	this()
	{
		imageStreams = [];
		videoStreams = [];
		audioStreams = [];
		textStreams = [];
	}

	/// copy constructor
	this(MediaInfoSig other)
	{
		imageStreams = other.imageStreams.dup;
		videoStreams = other.videoStreams.dup;
		audioStreams = other.audioStreams.dup;
		textStreams = other.textStreams.dup;
	}

	/// constructor with parameters
	@jsonize this(MediaInfoImage[] iStreams,
		MediaInfoVideo[] vStreams,
		MediaInfoAudio[] aStreams,
		MediaInfoText[] tStreams)
	{
		imageStreams = iStreams;
		videoStreams = vStreams;
		audioStreams = aStreams;
		textStreams = tStreams;
	}
	/// create a string from the object contents
	override string toString() const
	{
		string met = "MediaInfoSig(";
		auto mii = imageStreams.map!(a => a.toString).array();
		auto miv = videoStreams.map!(a => a.toString).array();
		auto mia = audioStreams.map!(a => a.toString).array();
		auto mit = textStreams.map!(a => a.toString).array();
		auto mi = chain(mii, miv, mia, mit).array();
		met ~= mi.join(", ");
		met ~= ")";
		return met;
	}

	/** Equality operator
	 * We use the string representation for equality testing.
	 */
	bool opEquals(const MediaInfoSig other) const
	{
		if (other is null)
			return false;
		return this.toString() == other.toString();
	}

	/** toHash implementation */
	// override size_t toHash() const
	// {
	// 	return this.toString().hashOf;
	// }

	// "perhaps implement `auto opOpAssign(string op : \"~\")(string) {}`"
	// auto opOpAssign(string op : "~")(string s)
	// {
	// 	// just ignore for now
	// }

	MediaInfoSig dup()
	{
		auto dupObj = new MediaInfoSig(this);
		return dupObj;
	}

	/** Check if the media info signature is empty
	 */
	bool empty() const
	{
		return imageStreams.length == 0 &&
			videoStreams.length == 0 &&
			audioStreams.length == 0 &&
			textStreams.length == 0;
	}
}

@("class MediaInfoSig")
unittest
{
	auto mii = new MediaInfoImage(0, "JPG", 320, 200);
	auto miv = new MediaInfoVideo(0, "de", "AV1", 320, 200, 25.0, 5000 * 1000, "1h");
	auto mia = new MediaInfoAudio(1, "de", "AAC", 6, 200_000, "1h");
	auto mit = new MediaInfoText(1, "de", "AAC", 0.10, 200_000, "1h");

	auto mis1 = new MediaInfoSig();
	assert(mis1.toString == "MediaInfoSig()", mis1.toString);
	auto mis2 = new MediaInfoSig([mii], [miv], [mia], [mit]);
	assert(mis2.toString == "MediaInfoSig(image0('JPG', 320x200), video0('de', 'AV1', 320x200, 25fps, 5000000bps, '1h'), audio1('de', 'AAC', 6 ch., 200000bps, '1h'), text1('de', 'AAC', 0.1fps, 200000bps, '1h'))", mis2
			.toString);

	auto mis9 = mis2.dup;
	assert(&mis9 != &mis2, "No different object");
	assert(&(mis9.videoStreams) != &(mis2.videoStreams), "No different object");
}

/** Get MediaInfo library version
 *
 * Returns: MediaInfo version string reported by the library.
 */
string getMediaInfoVersion()
{
	auto info = MediaInfo();
	const string vstring = info.option("Info_Version", "0.7.38.0;DTest;0.1");
	// logLine("Found version %s", vstring);
	if (vstring == "")
		throw new Exception("Incompatible mediainfo version");
	return vstring;
}

@("getMediaInfoVersion")
unittest
{
	auto mivers = getMediaInfoVersion();
	assert(mivers.length);
	assert(mivers.startsWith("MediaInfoLib - v"), mivers);
}

/** Parse bitrate string into ulong
 */
ulong parseBitRate(string bitrateStr) pure @safe
{
	ulong bitrateInt = 0;
	if (!bitrateStr.empty && !bitrateStr.startsWith("Unknown"))
	{
		try
		{
			bitrateInt = parse!ulong(bitrateStr);
		}
		catch (std.conv.ConvException ex)
		{
			debug
			{
				logFLine("%s:%s %s", __FUNCTION__, ex.msg, bitrateStr);
			}
		}
	}
	return bitrateInt;
}

/** Parse frame rate string into double
 */
double parseFrameRate(string frameRateStr) pure @safe
{
	double frameRateDbl = 0.0;
	if (!frameRateStr.empty && !frameRateStr.startsWith("Unknown"))
	{
		try
		{
			frameRateDbl = frameRateStr.to!double;
		}
		catch (Exception ex)
		{
			debug
			{
				logFLine("%s:%s %s", __FUNCTION__, ex.msg, frameRateStr);
				throw ex;
			}
		}
	}
	return frameRateDbl;
}

/** Parse integer string into ulong
 */
ulong parseInteger(string intStr) pure @safe
{
	ulong intVal = 0;
	if (!intStr.empty && !intStr.startsWith("Unknown"))
	{
		try
		{
			intVal = intStr.to!ulong;
		}
		catch (Exception ex)
		{
			debug
			{
				logFLine("%s:%s %s", __FUNCTION__, ex.msg, intStr);
				throw ex;
			}
		}
	}
	return intVal;
}

/** Parse an image stream from MediaInfo object
 */
MediaInfoImage parseImageStream(MediaInfo info, uint index)
{
	MediaInfoImage mii = null;
	try
	{
		mii = new MediaInfoImage(index,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Image, index, "Format"),
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Image, index, "Width").parseInteger,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Image, index, "Height").parseInteger);
	}
	catch (Exception ex)
	{
		logFLine("\n%s:%s:%d: %s", __FUNCTION__, ex.file, ex.line, ex.msg);
	}
	return mii;
}

/**
 * Parse a video stream from MediaInfo object
 */
MediaInfoVideo parseVideoStream(MediaInfo info, uint index)
{
	MediaInfoVideo ms = null;
	try
	{
		string bitrateStr = info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "BitRate");
		ulong bitrateInt = parseBitRate(bitrateStr);
		auto frameRate = info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "FrameRate");
		double frameRateDbl = parseFrameRate(frameRate);
		string language = info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "Language");

		ms = new MediaInfoVideo(index,
			language.empty ? null : language,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "Format"),
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "Width").parseInteger,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "Height").parseInteger,
			frameRateDbl,
			bitrateInt,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Video, index, "Duration/String"));
	}
	catch (Exception ex)
	{
		logFLine("\n%s:%s:%d: %s", __FUNCTION__, ex.file, ex.line, ex.msg);
	}
	return ms;
}

/**
 * Parse a audio stream from MediaInfo object
 */
MediaInfoAudio parseAudioStream(MediaInfo info, uint index)
{
	MediaInfoAudio ms = null;
	try
	{
		string bitrateStr = info.get(MediaInfo_stream_t.MediaInfo_Stream_Audio, index, "BitRate");
		ulong bitrateInt = parseBitRate(bitrateStr);
		string language = info.get(MediaInfo_stream_t.MediaInfo_Stream_Audio, index, "Language");
		ms = new MediaInfoAudio(index,
			language.empty ? null : language,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Audio, index, "Format"),
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Audio, index, "Channel(s)").parseInteger,
			bitrateInt,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Audio, index, "Duration/String"));
	}
	catch (Exception ex)
	{
		logFLine("\n%s:%s:%d: %s", __FUNCTION__, ex.file, ex.line, ex.msg);
	}
	return ms;
}

/**
 * Parse a text stream from MediaInfo object
 */
MediaInfoText parseTextStream(MediaInfo info, uint index)
{
	MediaInfoText ms = null;
	try
	{
		string bitrateStr = info.get(MediaInfo_stream_t.MediaInfo_Stream_Text, index, "BitRate");
		ulong bitrateInt = parseBitRate(bitrateStr);
		auto frameRate = info.get(MediaInfo_stream_t.MediaInfo_Stream_Text, index, "FrameRate");
		double frameRateDbl = parseFrameRate(frameRate);
		string language = info.get(MediaInfo_stream_t.MediaInfo_Stream_Text, index, "Language");
		language = language.empty ? null : language;
		return new MediaInfoText(index,
			language,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Text, index, "Format"),
			frameRateDbl,
			bitrateInt,
			info.get(MediaInfo_stream_t.MediaInfo_Stream_Text, index, "Duration/String"));
	}
	catch (Exception ex)
	{
		logFLine("\n%s:%s:%d: %s", __FUNCTION__, ex.file, ex.line, ex.msg);
	}
	return ms;
}

/** List of known media file extensions
 *
 * This list is used to distinguish between non-media files and media files
 * that just don't contain any media streams.
 * MediaInfo tends to crash on non-media files.
 */
immutable string[] knownMediaFileExtensions = [
	".3gp", ".3g2", ".aac", ".ac3", ".aiff", ".amr", ".asf", ".avi",
	".flac", ".flv", ".m4a", ".m4v", ".mkv", ".mov", ".mp3", ".mp4",
	".mpeg", ".mpg", ".mts", ".mxf", ".ogg", ".ogv", ".rmvb", ".wav",
	".wma", ".wmv", ".webm", ".vob", ".ts", ".sub", ".srt", ".ass",
	".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff"
];

/** Check whether a filename ends with a known media file extension.
 *
 * Params:
 *   filename = file path to inspect
 * Returns:
 *   true if the extension is known to be media-related
 */
bool hasMediaFileExtension(string filename) pure @safe
{
	import std.path : extension;
	import std.algorithm.searching : find;

	auto ext = extension(filename).toLower();
	auto fnd = knownMediaFileExtensions.find(ext);
	return !fnd.empty;
}

/** Create a media signature for a file.
 *
 *  Uses the MediaInfo library to extract image/video/audio/text stream metadata.
 *
 * Params:
 *   filename = existing file to analyze
 * Returns:
 *   MediaInfoSig object on success, or null when the file is missing,
 *   not recognized as media by extension, or MediaInfo parsing fails.
 */
MediaInfoSig getMediaTypeSignature(const string filename)
{
	// Examine only known media file extensions
	if (!hasMediaFileExtension(filename))
	{
		return null;
	}

	MediaInfoSig mediasigs;
	mediasigs = new MediaInfoSig([], [], [], []);

	if (!exists(filename))
		return null;
	auto fh = File(filename);
	if (fh.size)
	{
		// Open MediaInfo and extract info

		auto info = MediaInfo();
		info.option("Internet", "No");

		string bitrateStr;
		int bitrateInt;
		try
		{
			info.open(filename);
			scope (exit)
				info.close();

			/+
		const string sFileName = info.get(MediaInfo_stream_t.MediaInfo_Stream_General,
				0, "FileName");
		if (!sFileName.empty) mediasigs ~= format("<filename:%s>", sFileName);
		+/
			const ulong nImage = info.getCount(MediaInfo_stream_t.MediaInfo_Stream_Image);
			const ulong nVideo = info.getCount(MediaInfo_stream_t.MediaInfo_Stream_Video);
			const ulong nAudio = info.getCount(MediaInfo_stream_t.MediaInfo_Stream_Audio);
			const ulong nText = info.getCount(MediaInfo_stream_t.MediaInfo_Stream_Text);

			if (nImage == 0 && nText == 0 && nVideo == 0 && nAudio == 0)
			{
				return mediasigs;
			}

			for (uint i = 0; i < nImage; i++)
			{
				auto ms = parseImageStream(info, i);
				mediasigs.imageStreams ~= ms;
			}
			for (uint i = 0; i < nVideo; i++)
			{
				auto ms = parseVideoStream(info, i);
				mediasigs.videoStreams ~= ms;
			}
			for (uint i = 0; i < nAudio; i++)
			{
				auto ms = parseAudioStream(info, i);
				mediasigs.audioStreams ~= ms;
			}
			for (uint i = 0; i < nText; i++)
			{
				auto ms = parseTextStream(info, i);
				mediasigs.textStreams ~= ms;
			}
		}
		catch (MediaInfoException ex)
		{
			logFLine("%s %s", ex.msg, filename);
			return null;
		}
		catch (std.conv.ConvException ex)
		{
			logFLine("\n%s:%s:%d: %s", __FUNCTION__, ex.file, ex.line, ex.msg);

			return null;
		}
	}
	return mediasigs;
}

/** Unit test for getMediaTypeSignature
 *
*/
@("getMediaTypeSignature")
unittest
{
	auto sig = getMediaTypeSignature("test/non-existing-file.txt");
	assert(sig is null);

	auto sig1 = getMediaTypeSignature("test/dummy-text-file.txt");
	assert(sig1 is null);

	auto sig2 = getMediaTypeSignature("test/dummy-audio-file.mp3");
	auto sig2ref = new MediaInfoSig(
		[],
		[],
		[new MediaInfoAudio(0, "", "MPEG Audio", 2, 170_091, "38 s 217 ms")],
		[]);
	assert(sig2 == sig2ref, "Expected: %s, got: %s".format(sig2ref, sig2));

	auto sig3 = getMediaTypeSignature("test/dummy-video-file.mp4.mkv");
	auto sig3ref = new MediaInfoSig(
		[],
		[new MediaInfoVideo(0, "", "AV1", 1920, 1080, 30.147, 0, "5 s 108 ms")],
		[new MediaInfoAudio(0, "en", "AAC", 2, 0, "5 s 122 ms")],
		[]);
	assert(sig3 == sig3ref, "Expected: %s, got: %s".format(sig3ref, sig3));

	auto sig4 = getMediaTypeSignature("test/dummy-picture-file.jpg");
	assert(sig4 !is null);
	assert(sig4.imageStreams.length >= 1, "Expected at least one image stream");
	assert(sig4.imageStreams[0].format == "JPEG", sig4.to!string);
	assert(sig4.imageStreams[0].width == 3264, sig4.to!string);
	assert(sig4.imageStreams[0].height == 2448, sig4.to!string);
	// Some MediaInfo builds expose an additional thumbnail stream, some do not.
	if (sig4.imageStreams.length >= 2)
	{
		assert(sig4.imageStreams[1].format == "JPEG", sig4.to!string);
		assert(sig4.imageStreams[1].width == 320, sig4.to!string);
		assert(sig4.imageStreams[1].height == 240, sig4.to!string);
	}

	auto sig5 = getMediaTypeSignature("test/dummy-subtitle-file.srt");
	auto sig5ref = new MediaInfoSig(
		[],
		[],
		[],
		[new MediaInfoText(0, "", "SubRip", 0.0, 0, "52 min 28 s")]);
	assert(sig5 == sig5ref, "Expected: %s, got: %s".format(sig5ref, sig5));

	// logFLine("Text file media sig: %s", sig1);
	// logFLine("Audio file media sig: %s", sig2);
	// logFLine("Video file media sig: %s", sig3);
	// logFLine("Picture file media sig: %s", sig4);
	// logFLine("Subtitle file media sig: %s", sig5);
}

/** Parse media info signature from media info lines
 *
 * Param:
 *   mediaInfo = Array of media info lines
 * Returns: Parsed MediaInfoSig object
 */
/* Example data:
		"mediaInfo": [
		"<video:0, 1918 x 1040 @ 23.976, 0kbps, 1 h 28 min, HEVC>",
		"<audio:0, 6 ch., 1 h 28 min, 0kbps ?, AAC>",
		"<audio:1, 6 ch., 1 h 28 min, 0kbps ?, AAC>",
		"<text:0, de, ?, ?, 0kbps, ASS>"
		"<text:0, en, 0.316, 1 h 46 min, 21kbps, PGS>",
		"<text:1, ar, 0.276, 1 h 53 min, 10kbps, PGS>",
		"<text:2, da, 0.261, 1 h 53 min, 16kbps, PGS>",

*/
MediaInfoSig parseMediaInfoSignature(string[] mediaInfo)
{
	import std.string : split;
	import std.regex;

	MediaInfoSig mis = new MediaInfoSig();
	foreach (line; mediaInfo)
	{
		auto parts = line.split(":");
		if (parts.length != 2)
			continue;
		auto key = parts[0].strip();
		auto value = parts[1].strip();
		switch (key)
		{
		case "<image":
			auto ctr = ctRegex!(`^(\d+), (\d+) x (\d+), (\w+)>$`);
			auto c2 = value.matchFirst(ctr);
			assert(!c2.empty, value); // Be sure to check if there is a match before examining contents!
			assert(c2.length == 5, value);

			auto idx = c2[1].to!uint;
			auto w = c2[2].to!uint;
			auto h = c2[3].to!uint;
			auto codec = c2[4].to!string;

			auto mii = new MediaInfoImage(idx, codec.to!string, w, h);
			mis.imageStreams ~= mii;
			break;
		case "<video":
			auto ctr = ctRegex!(`^(\d+), (\d+) x (\d+) @ (\S*), (\d+)kbps, (.*), (.+)>$`);
			auto c2 = value.matchFirst(ctr);
			assert(!c2.empty, value); // Be sure to check if there is a match before examining contents!
			assert(c2.length == 8, value);

			auto idx = c2[1].to!uint;
			auto w = c2[2].to!uint;
			auto h = c2[3].to!uint;
			auto rate = c2[4].empty ? 0.0 : c2[4].to!float;
			auto kbps = c2[5].to!uint * 1000;
			auto playtime = c2[6].to!string;
			auto codec = c2[7].to!string;

			auto miv =
				new MediaInfoVideo(idx, "un", codec.to!string, w, h, rate, kbps, playtime
						.to!string);
			mis.videoStreams ~= miv;

			break;
		case "<audio":
			auto ctr = ctRegex!(`^(\d+), (\d+) ch., (.+), (\d+)kbps (.+), (.+)>$`);
			auto c2 = value.matchFirst(ctr);
			assert(!c2.empty, value); // Be sure to check if there is a match before examining contents!
			assert(c2.length == 7, value);

			auto idx = c2[1].to!uint;
			auto ch = c2[2].to!uint;
			auto playtime = c2[3].to!string;
			auto br = c2[4].to!uint * 1000;
			auto lang = c2[5].to!string;
			auto codec = c2[6].to!string;

			auto mia = new MediaInfoAudio(idx, lang, codec.to!string, ch, br, playtime.to!string);
			mis.audioStreams ~= mia;
			break;
		case "<text":
			auto ctr = ctRegex!(`^(\d+), (\w*), (\S+), (.+), (\d+)kbps, (\S+)>$`);
			auto c2 = value.matchFirst(ctr);
			assert(!c2.empty, value); // Be sure to check if there is a match before examining contents!
			assert(c2.length == 7, value);

			auto idx = c2[1].to!uint;
			auto lang = c2[2] == "?" || c2[2].empty ? "" : c2[2].to!string;
			auto fr = c2[3] == "?" ? 0.0 : c2[3].to!float;
			auto playtime = c2[4] == "?" ? "" : c2[4].to!string;
			auto br = c2[5].to!uint * 1000;
			auto codec = c2[6].to!string;

			auto mit =
				new MediaInfoText(idx, codec.to!string, lang.to!string, fr, br, playtime.to!string);
			mis.textStreams ~= mit;
			break;
		default:
			assert(false, "Unknown media info type: " ~ key);
		}
	}
	return mis;
}
