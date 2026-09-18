# JSON Storage Format

This document describes the JSON format currently used by DosierSkanilo for
import and export. It describes version 3, which is the format written by the
current application.

JSON is a compatibility and exchange format. It is not intended to be the
primary query store for large repositories. The `.dosierskanilo` SQLite
repository is the normal working store and is described in [DATABASE.md](DATABASE.md).
The direct JSON-file workflow remains supported for existing users, scripts and
catalogs and is not scheduled for short-term removal.

## Root Object

The current format writes one JSON object:

```json
{
    "dataArray": [],
    "dataVersion": 3,
    "fileUtilityVersion": "file-5.47",
    "mediaInfoVersion": "MediaInfoLib - v26.01"
}
```

- `dataVersion` (integer): Storage schema version. Current value: `3`.
- `dataArray` (array): Array of binary-content records.
- `fileUtilityVersion` (optional string): Version of the external `file`
  utility used for the scan.
- `mediaInfoVersion` (optional string): Version of the MediaInfo library used
  for the scan.

The two tool-version fields describe the environment that produced the
metadata. They are not a version of the JSON schema itself.

## Binary Content Records

Each element of `dataArray` represents one binary payload. Several filesystem
paths can refer to the same payload after duplicate analysis.

- `fileSize` (integer): Payload size in bytes.
- `checkSums` (optional object): MD5, SHA1 and XXH64 values encoded as
  Base64 strings.
- `fileType` (optional string): Output of the `file` utility.
- `fileName` (optional string): Single filesystem path. Used when the record
  has one path.
- `timeLastModified` (optional string): ISO timestamp belonging to `fileName`.
- `fileSpecs` (optional array): Filesystem paths and timestamps. Used when the
  record has multiple paths.
- `mediaInfoSig` (optional object): Structured image, video, audio and text
  stream metadata.
- `archiveSpecs` (optional array): Metadata and checksums for entries inside an
  archive.
- `torrentInfo` (optional object): Selected torrent metadata.

### Checksums

`checkSums` can contain these fields:

```json
{
    "md5sum_b64": "...",
    "sha1sum_b64": "...",
    "xxh64sum_b64": "..."
}
```

The application currently treats a record as fully checksummed only when all
three values are present. Duplicate analysis groups records by size and then
by SHA1, while equality also requires complete checksum data.

### Filesystem References

The in-memory model always normalizes paths to `fileSpecs` objects:

```json
"fileSpecs": [
    {
        "fileName": "/media/video/movie.mkv",
        "timeLastModified": "2026-09-17T12:34:56"
    }
]
```

For compatibility, the writer uses the shorter representation for exactly one
path:

```json
{
    "fileName": "/media/video/movie.mkv",
    "timeLastModified": "2026-09-17T12:34:56"
}
```

This is an output optimization, not a different domain concept. On input,
both forms are converted to `fileSpecs` by `fixupDataClassArrayIn()`.

### MediaInfo

`mediaInfoSig` contains up to four arrays:

- `imageStreams`: `index`, `format`, `width`, `height`
- `videoStreams`: `index`, `language`, `format`, `width`, `height`,
  `frameRate`, `bitRate`, `duration`
- `audioStreams`: `index`, `language`, `format`, `channels`, `bitRate`,
  `duration`
- `textStreams`: `index`, `language`, `format`, `frameRate`, `bitRate`,
  `duration`

Empty media signatures are removed before output. JPEG files identified as
still images by `file` are normalized if MediaInfo reported their JPEG stream
as a video stream.

### Archive Entries

Each element of `archiveSpecs` contains:

- `fileName` (string): Path of the entry inside the archive.
- `fileSize` (integer): Entry size in bytes.
- `timeLastModified` (string): Entry modification timestamp.
- `checkSums` (optional object): MD5, SHA1 and XXH64 values for the extracted
  entry.

Archive entries belong to the binary record of the archive file itself.

### Torrent Information

The current JSON writer outputs these `torrentInfo` fields:

- `name` (string): Torrent display name.
- `magnetURI` (string): Magnet URI generated from the info hash.
- `totalSize` (integer): Total size of the torrent content.

The in-memory `TorrentInfo` model also contains `isMultiFile`, `files`,
`infoHashHex`, `announce`, `pieceLength` and `piecesCount`. These fields are
currently marked as input-only and are not written to the version-3 JSON
format. A future extended JSON version must be introduced before these fields
can be exported without information loss.

## Versions and Migration

The reader supports the following historical forms:

- A legacy root-level JSON array without a wrapper object.
- Version 1 wrapper data with legacy scalar filename and checksum fields.
- Version 2 and version 3 wrapper data.
- Legacy fields such as `fileNames`, `mediaInfo`, `md5sum_b64`, `sha1sum_b64`
  and `xxh64sum_b64` inside a record.

During input migration:

1. `fileName` and `fileNames` are converted to `fileSpecs`.
2. Legacy checksum fields are copied into `checkSums`.
3. Legacy textual MediaInfo is parsed into `mediaInfoSig`.
4. Invalid empty torrent and media records are removed.
5. The in-memory catalog is normalized to version 3.

During output migration:

1. Records are sorted by their first path.
2. Duplicate path records are reduced to one record.
3. A single path uses `fileName` and `timeLastModified`.
4. Multiple paths use `fileSpecs`.
5. Legacy fields are cleared before serialization.

The relevant implementation is in
`source/dosierskanilo/model/namedbinaryblob.d`, especially
`fixupDataClassArrayIn()`, `fixupDataClassArrayOut()` and the wrapper
serialization functions.

## Import and Export Rules for SQLite

SQLite import must normalize every supported JSON representation into the
relational model. JSON export must construct the required relationship closure:
a filtered export must include each selected file reference together with its
referenced binary record and selected metadata.

The existing version-3 writer remains available for compatibility. If SQLite
stores fields that version 3 cannot represent, an extended JSON version must
be added rather than silently dropping those fields.
