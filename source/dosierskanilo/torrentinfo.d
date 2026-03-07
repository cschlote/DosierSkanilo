/** Minimal BitTorrent `.torrent` file analyzer.
 *
 * Extracts the info-hash, magnet URI, basic metadata, and file list.
 *
 * References:
 *   - BitTorrent v1 Specification:
 *     https://www.bittorrent.org/beps/bep_0003.html
 *
 *   - Bencoding Specification:
 *     https://www.bittorrent.org/beps/bep_0003.html#bencoding
 *
 *   - Magnet URI Scheme:
 *     https://www.bittorrent.org/beps/bep_0009.html
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module dosierskanilo.torrentinfo;

import std.file;
import std.digest.sha;
import std.conv;
import std.array;
import std.exception;
import std.string;
import std.algorithm;
import std.format;
import std.sumtype;

import logging;
import jsonizer;

/** Represents a single file in a torrent.
 */
class TorrentFileEntry
{
    mixin JsonizeMe;

    @jsonize(JsonizeIn.opt, JsonizeOut.opt)
    {
        string[] path; /// Path components relative to torrent root
        ulong length; /// File size in bytes
    }
}

/** Class representing extracted torrent metadata.
 */
class TorrentInfo
{
    mixin JsonizeMe;

    @jsonize(JsonizeIn.opt, JsonizeOut.opt)
    {
        string name; /// Torrent display name
        string magnetURI; /// Magnet URI (btih, hex encoded)
        ulong totalSize; /// Total size of all files in bytes
    }

    @jsonize(JsonizeIn.opt, JsonizeOut.no)
    {
        bool isMultiFile; /// True if multi-file torrent
        TorrentFileEntry[] files; /// List of files
        /** SHA1 hash of the bencoded `info` dictionary (hex encoded)
        * See:  https://www.bittorrent.org/beps/bep_0003.html#info-hash */
        string infoHashHex;
        string announce; /// Primary announce tracker
        ulong pieceLength; /// Piece length in bytes
        /**
        Number of SHA1 piece hashes contained in `info.pieces`
        Each piece hash is 20 bytes (SHA1).
        See:
        https://www.bittorrent.org/beps/bep_0003.html#pieces
        */
        ulong piecesCount; /// Number of pieces
    }

    bool empty() const
    {
        return
            magnetURI.length == 0 &&
            name.length == 0 &&
            totalSize == 0
            // infoHashHex.length == 0 &&
            // announce.length == 0 &&
            // pieceLength == 0 &&
            // piecesCount == 0 &&
            // files.length == 0
            ;
    }
}

/** Parse a `.torrent` file and extract relevant metadata.
 *
 * Params:
 *   filePath = Path to the `.torrent` file
 *
 * Returns:
 *   A newly allocated `TorrentInfo` object
 *
 * Throws:
 *   Exception if the file is invalid or unreadable
 */
TorrentInfo getTorrentInfo(string filePath)
{
    enforce(exists(filePath), "Torrent file does not exist");
    enforce(isFile(filePath), "Path is not a file");
    enforce(filePath.endsWith(".torrent"), "File does not have .torrent extension");

    auto rawData = cast(ubyte[]) read(filePath);

    auto parser = new BencodeParser(rawData);
    auto root = parser.parseRoot();

    enforce("info" in root, "Invalid torrent file: missing 'info' element");

    auto infoNode = root["info"];
    enforce(infoNode.value.has!BDict, "Invalid torrent file '%s': info is not a dictionary"
            .format(filePath));
    auto infoDict = infoNode.value.get!BDict;

    // Encode info dict for hash
    Appender!(ubyte[]) encodedInfo;
    bencode(encodedInfo, infoNode);
    auto hash = sha1Of(encodedInfo.data);
    auto hashHex = toHex(hash);

    auto ti = new TorrentInfo();
    ti.totalSize = 0;
    ti.isMultiFile = false;

    ti.infoHashHex = hashHex;
    ti.magnetURI = "magnet:?xt=urn:btih:" ~ hashHex;

    // Optional metadata
    if ("announce" in root)
        ti.announce = root["announce"].value.get!string;

    if ("name" in infoDict)
        ti.name = infoDict["name"].value.get!string;

    if ("piece length" in infoDict)
        ti.pieceLength = infoDict["piece length"].value.get!long;

    if ("pieces" in infoDict)
    {
        enum sizePieceHash = 20; // SHA1
        auto piecesData = infoDict["pieces"].value.get!string;
        enforce(piecesData.length % sizePieceHash == 0,
            "Invalid pieces field length");
        ti.piecesCount = cast(ulong) piecesData.length / sizePieceHash;
    }

    // Files and total size
    ti.files = [];
    if ("length" in infoDict)
    {
        // Single file
        ti.isMultiFile = false;
        auto fe = new TorrentFileEntry();
        fe.path = [ti.name];
        fe.length = infoDict["length"].value.get!long;
        ti.files ~= fe;
        ti.totalSize = fe.length;
    }
    else if ("files" in infoDict)
    {
        // Multi-file
        ti.isMultiFile = true;
        ulong sum;
        foreach (fileEntry; infoDict["files"].value.get!BList)
        {
            auto dict = fileEntry.value.get!BDict;
            auto fe = new TorrentFileEntry();
            fe.length = dict["length"].value.get!long;

            auto pathList = dict["path"].value.get!BList;
            auto relativePath = pathList.map!(p => p.value.get!string).array;
            fe.path = [ti.name] ~ relativePath;

            ti.files ~= fe;
            sum += fe.length;
        }
        ti.totalSize = sum;
    }

    return ti;
}

/** Recursive bencode node.
 *
 * Required indirection because SumType does not allow
 * directly recursive aliases.
 */
struct BNode
{
    BValue value;
}

/// Internal representation of a bencoded value
alias BValue = SumType!(long, string, BList, BDict);

/// Bencoded list
alias BList = BNode[];

/// Bencoded dictionary
alias BDict = BNode[string];

/* ============================================================
 * Bencode Parser
 * ============================================================
 */

class BencodeParser
{
    private const(ubyte)[] data;
    private size_t pos;

    this(const(ubyte)[] data)
    {
        this.data = data;
        this.pos = 0;
    }

    BDict parseRoot()
    {
        auto node = parseValue();
        return node.value.get!BDict;
    }

    BNode parseValue()
    {
        enforce(pos < data.length, "Unexpected end of file");

        switch (data[pos])
        {
        case 'i':
            return parseInt();
        case 'l':
            return parseList();
        case 'd':
            return parseDict();
        default:
            if (data[pos] >= '0' && data[pos] <= '9')
                return parseString();
            throw new Exception("Invalid bencode format");
        }
    }

    BNode parseInt()
    {
        pos++;
        auto start = pos;
        while (pos < data.length && data[pos] != 'e')
            pos++;
        enforce(pos < data.length, "Unterminated integer");
        auto value = to!long(cast(string) data[start .. pos]);
        pos++;
        return BNode(BValue(value));
    }

    BNode parseString()
    {
        auto start = pos;
        while (pos < data.length && data[pos] != ':')
            pos++;
        enforce(pos < data.length, "Invalid string length");
        auto len = to!size_t(cast(string) data[start .. pos]);
        pos++;
        enforce(pos + len <= data.length, "Unexpected EOF in string");
        auto s = cast(string) data[pos .. pos + len];
        pos += len;
        return BNode(BValue(s));
    }

    BNode parseList()
    {
        pos++;
        BList list;
        while (pos < data.length && data[pos] != 'e')
            list ~= parseValue();
        enforce(pos < data.length, "Unterminated list");
        pos++;
        return BNode(BValue(list));
    }

    BNode parseDict()
    {
        pos++;
        BDict dict;
        while (pos < data.length && data[pos] != 'e')
        {
            auto key = parseValue().value.get!string;
            dict[key] = parseValue();
        }
        enforce(pos < data.length, "Unterminated dictionary");
        pos++;
        return BNode(BValue(dict));
    }
}

/** Bencode Encoder (for info dictionary hashing) */
void bencode(ref Appender!(ubyte[]) out_, BNode node)
{
    node.value.match!(
        (long i) {
        out_.put('i');
        out_.put(cast(ubyte[]) to!string(i));
        out_.put('e');
    },
        (string s) {
        out_.put(cast(ubyte[]) to!string(s.length));
        out_.put(':');
        out_.put(cast(ubyte[]) s);
    },
        (BList list) {
        out_.put('l');
        foreach (e; list)
            bencode(out_, e);
        out_.put('e');
    },
        (BDict dict) {
        out_.put('d');
        foreach (k; dict.keys.sort)
        {
            out_.put(cast(ubyte[]) to!string(k.length));
            out_.put(':');
            out_.put(cast(ubyte[]) k);
            bencode(out_, dict[k]);
        }
        out_.put('e');
    }
    );
}

/** Convert a byte array to lowercase hexadecimal string */
string toHex(const ubyte[] data)
{
    string result;
    foreach (b; data)
        result ~= format("%02x", b);
    return result;
}

/* ============================================================
 * Unit Tests
 * ============================================================
 */

@("getTorrentInfo - single file torrent")
unittest
{
    import std.stdio : File;

    auto ti0 = new TorrentInfo();
    assert(ti0.empty, "New TorrentInfo should be empty");

    auto ti = getTorrentInfo("test/example.torrent");
    assert(ti.infoHashHex == "2c423fe994bf512d4c786ae3f46329c3ce9a5369");
    assert(startsWith(ti.magnetURI, "magnet:?xt=urn:btih:"));
    assert(ti.name == "dummy-video-file.mp4.mkv");
    assert(!ti.isMultiFile);
    auto fh = File("test/dummy-video-file.mp4.mkv", "rb");
    auto size = fh.size;
    assert(ti.totalSize == size, ti.totalSize.to!string);
    assert(ti.files.length == 1, ti.files.length.to!string);
    assert(ti.files[0].length == size);
    assert(ti.files[0].path == ["dummy-video-file.mp4.mkv"]);
}

@("getTorrentInfo - multi file torrent")
unittest
{
    auto ti = getTorrentInfo("test/test-multifile.torrent");
    assert(ti.infoHashHex == "0f43d6fb308b289e9c443a9fc0095b40a0f27a4e");
    assert(startsWith(ti.magnetURI, "magnet:?xt=urn:btih:"));
    assert(ti.name == "multifile_tmp");
    assert(ti.isMultiFile);
    assert(ti.files.length > 1);
    ulong sum = 0;
    foreach (f; ti.files)
    {
        assert(f.path.length >= 1);
        import std.stdio : writeln;

        // writeln(f.path.join("/"));
        sum += f.length;
    }
    assert(ti.totalSize == sum);
}
