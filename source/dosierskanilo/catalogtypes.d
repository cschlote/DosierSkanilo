/** Value types of the storage-neutral catalog contract.
 *
 *
 * Identities, locators, queries, pages, and capability descriptors are
 * shared by the JSON and SQLite backends and by the GUI.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.catalogtypes;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.string : split, startsWith;
import dosierskanilo.operations : OperationKind, OperationStorageMode;

/** Opaque identity of one content record in one catalog source. */
struct ContentId
{
    /// Opaque adapter-issued token; non-empty for every valid identity.
    package string token;

    /** Wrap a non-empty adapter token as a content identity.
     *
     * Params:
     *     token = Opaque adapter token; must not be empty.
     * Throws: `Exception` when the token is empty.
     */
    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ContentId token cannot be empty.");
        this.token = token;
    }

    /** Expose the opaque token to catalog adapters in this package.
     *
     * Returns: The stored adapter token; empty for a default/invalid identity.
     */
    package(dosierskanilo) @property string adapterToken() const { return token; }

    /** Whether an adapter-issued identifier has been assigned.
     *
     * Returns: `true` when the opaque token is non-empty.
     */
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /** Compare identifiers within their catalog-source scope.
     *
     * Params:
     *     other = Identifier to compare against.
     * Returns: `true` when both identifiers carry the same opaque token.
     */
    bool opEquals(const ContentId other) const
    {
        return token == other.token;
    }

    /** Stable hash within this identifier's source scope.
     *
     * Returns: The hash of the opaque token.
     */
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /** Redacted display value that does not expose the opaque token.
     *
     * Returns: A constant description that reveals only the identifier kind
     *     and whether it is valid.
     */
    string toString() const
    {
        return isValid ? "ContentId(<opaque>)" : "ContentId(<invalid>)";
    }
}

/** Opaque identity of one reference/location in one catalog source. */
struct ReferenceId
{
    /// Opaque adapter-issued token; non-empty for every valid identity.
    package string token;

    /** Wrap a non-empty adapter token as a reference identity.
     *
     * Params:
     *     token = Opaque adapter token; must not be empty.
     * Throws: `Exception` when the token is empty.
     */
    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ReferenceId token cannot be empty.");
        this.token = token;
    }

    /** Expose the opaque token to catalog adapters in this package.
     *
     * Returns: The stored adapter token; empty for a default/invalid identity.
     */
    package(dosierskanilo) @property string adapterToken() const { return token; }

    /** Whether an adapter-issued identifier has been assigned.
     *
     * Returns: `true` when the opaque token is non-empty.
     */
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /** Compare identifiers within their catalog-source scope.
     *
     * Params:
     *     other = Identifier to compare against.
     * Returns: `true` when both identifiers carry the same opaque token.
     */
    bool opEquals(const ReferenceId other) const
    {
        return token == other.token;
    }

    /** Stable hash within this identifier's source scope.
     *
     * Returns: The hash of the opaque token.
     */
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /** Redacted display value that does not expose the opaque token.
     *
     * Returns: A constant description that reveals only the identifier kind
     *     and whether it is valid.
     */
    string toString() const
    {
        return isValid ? "ReferenceId(<opaque>)" : "ReferenceId(<invalid>)";
    }
}

/** Opaque identity of a directory projection in one catalog source. */
struct DirectoryId
{
    /// Opaque adapter-issued token; non-empty for every valid identity.
    package string token;

    /** Wrap a non-empty adapter token as a directory identity.
     *
     * Params:
     *     token = Opaque adapter token; must not be empty.
     * Throws: `Exception` when the token is empty.
     */
    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "DirectoryId token cannot be empty.");
        this.token = token;
    }

    /** Expose the opaque token to catalog adapters in this package.
     *
     * Returns: The stored adapter token; empty for a default/invalid identity.
     */
    package(dosierskanilo) @property string adapterToken() const { return token; }

    /** Whether an adapter-issued identifier has been assigned.
     *
     * Returns: `true` when the opaque token is non-empty.
     */
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /** Compare identifiers within their catalog-source scope.
     *
     * Params:
     *     other = Identifier to compare against.
     * Returns: `true` when both identifiers carry the same opaque token.
     */
    bool opEquals(const DirectoryId other) const
    {
        return token == other.token;
    }

    /** Stable hash within this identifier's source scope.
     *
     * Returns: The hash of the opaque token.
     */
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /** Redacted display value that does not expose the opaque token.
     *
     * Returns: A constant description that reveals only the identifier kind
     *     and whether it is valid.
     */
    string toString() const
    {
        return isValid ? "DirectoryId(<opaque>)" : "DirectoryId(<invalid>)";
    }
}

/** Opaque entry identity scoped to a container content/index version. */
struct ArchiveEntryId
{
    /// Opaque adapter-issued token; non-empty for every valid identity.
    package string token;

    /** Wrap a non-empty adapter token as an archive-entry identity.
     *
     * Params:
     *     token = Opaque adapter token; must not be empty.
     * Throws: `Exception` when the token is empty.
     */
    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ArchiveEntryId token cannot be empty.");
        this.token = token;
    }

    /** Expose the opaque token to catalog adapters in this package.
     *
     * Returns: The stored adapter token; empty for a default/invalid identity.
     */
    package(dosierskanilo) @property string adapterToken() const { return token; }

    /** Whether an adapter-issued identifier has been assigned.
     *
     * Returns: `true` when the opaque token is non-empty.
     */
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /** Compare identifiers within their container-index scope.
     *
     * Params:
     *     other = Identifier to compare against.
     * Returns: `true` when both identifiers carry the same opaque token.
     */
    bool opEquals(const ArchiveEntryId other) const
    {
        return token == other.token;
    }

    /** Stable hash within this identifier's container-index scope.
     *
     * Returns: The hash of the opaque token.
     */
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /** Redacted display value that does not expose the opaque token.
     *
     * Returns: A constant description that reveals only the identifier kind
     *     and whether it is valid.
     */
    string toString() const
    {
        return isValid ? "ArchiveEntryId(<opaque>)" : "ArchiveEntryId(<invalid>)";
    }
}

/** Opaque position in one source/query/sort result sequence. */
struct CatalogPageCursor
{
    /// Zero-based offset of the first row described by this cursor.
    package size_t index;
    /// Page size this cursor was issued for; later requests must match it.
    package size_t pageSize;
    /// Source/query/sort binding used to reject foreign cursors.
    package(dosierskanilo) string queryToken;
    /// True only for continuation cursors returned by a backend.
    package bool valid;

    /** Create a validated continuation cursor.
     *
     * Params:
     *     index = Zero-based offset of the first row on the next page.
     *     pageSize = Page size the cursor is bound to; must be positive.
     *     queryToken = Source/query/sort binding; must not be empty.
     * Throws: `Exception` when the page size or query token is invalid.
     */
    package(dosierskanilo) this(size_t index, size_t pageSize,
        string queryToken)
    {
        enforce(pageSize > 0, "Catalog page cursor size must be positive.");
        enforce(queryToken.length > 0, "Catalog page cursor query token cannot be empty.");
        this.index = index;
        this.pageSize = pageSize;
        this.queryToken = queryToken;
        this.valid = true;
    }

    /** Expose the row offset to catalog adapters in this package.
     *
     * Returns: The zero-based offset of the first row described by the cursor.
     */
    package(dosierskanilo) @property size_t adapterIndex() const { return index; }
    /** Expose the bound page size to catalog adapters in this package.
     *
     * Returns: The page size this cursor was issued for.
     */
    package(dosierskanilo) @property size_t adapterPageSize() const { return pageSize; }
    /** Expose the query binding token to catalog adapters in this package.
     *
     * Returns: The source/query/sort binding token.
     */
    package(dosierskanilo) @property string adapterQueryToken() const { return queryToken; }

    /** Whether this is a continuation cursor rather than the first-page marker.
     *
     * Returns: `true` only for cursors issued by a backend.
     */
    @property bool isValid() const
    {
        return valid;
    }

    /** Compare opaque continuation values.
     *
     * Params:
     *     other = Cursor to compare against.
     * Returns: `true` when index, page size, query token, and validity match.
     */
    bool opEquals(const CatalogPageCursor other) const
    {
        return index == other.index && pageSize == other.pageSize
            && queryToken == other.queryToken && valid == other.valid;
    }

    /** Stable hash without revealing the query/source-bound cursor token.
     *
     * Returns: A hash derived from the query token, row offset, and page size.
     */
    size_t toHash() const nothrow @safe
    {
        return queryToken.hashOf ^ index ^ pageSize;
    }

    /** Redacted display value that does not expose source/query state.
     *
     * Returns: `<opaque>` for a continuation cursor, `<initial>` otherwise.
     */
    string toString() const
    {
        return isValid ? "CatalogPageCursor(<opaque>)"
            : "CatalogPageCursor(<initial>)";
    }
}

/** Filesystem location relative to the source root bound to the backend. */
struct FilesystemLocator
{
    string relativePath; /// Normalized path relative to the bound source root.
}

/** Structured locator for an archive member; names are not entry identities. */
struct ArchiveEntryLocator
{
    ReferenceId containerReferenceId; /// The reference that owns the container.
    ArchiveEntryId entryId; /// Unique occurrence in that container's current index.
}

/** A physical file or archive-member location, represented without display paths. */
struct ContentLocator
{
    /** Discriminator for the populated locator payload. */
    enum Kind
    {
        none, /// Invalid/empty locator.
        filesystem, /// Root-relative physical file.
        archiveEntry /// Entry in an archive container reference.
    }

    Kind kind; /// Selects which locator payload is populated.
    FilesystemLocator filesystem; /// Payload for `Kind.filesystem`.
    ArchiveEntryLocator archiveEntry; /// Payload for `Kind.archiveEntry`.

    /** Construct a validated source-root-relative filesystem locator.
     *
     * Params:
     *     relativePath = Normalized path from the source root; must not be
     *         absolute, contain backslashes or a drive prefix, or contain
     *         empty, `.` or `..` components.
     * Returns: A locator with `Kind.filesystem` populated.
     * Throws: `CatalogBackendException` with `invalidLocator` when the path is
     *     not a normalized source-relative path.
     */
    static ContentLocator file(string relativePath)
    {
        bool valid = relativePath.length > 0
            && !relativePath.startsWith("/")
            && !relativePath.startsWith("\\")
            && !relativePath.canFind('\\')
            && !(relativePath.length >= 2 && relativePath[1] == ':');
        if (valid)
            foreach (part; relativePath.split("/"))
                if (part.length == 0 || part == "." || part == "..")
                {
                    valid = false;
                    break;
                }
        if (!valid)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidLocator,
                "Filesystem locator must be a normalized source-relative path.");
        ContentLocator locator;
        locator.kind = Kind.filesystem;
        locator.filesystem.relativePath = relativePath;
        return locator;
    }

    /** Construct a validated archive-entry locator chain element.
     *
     * Params:
     *     container = Reference that owns the container; must be valid.
     *     entryId = Entry identity within that container; must be valid.
     * Returns: A locator with `Kind.archiveEntry` populated.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when either
     *     identity is invalid.
     */
    static ContentLocator entry(ReferenceId container, ArchiveEntryId entryId)
    {
        if (!container.isValid || !entryId.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Archive locators require valid container and entry identities.");
        ContentLocator locator;
        locator.kind = Kind.archiveEntry;
        locator.archiveEntry = ArchiveEntryLocator(container, entryId);
        return locator;
    }
}

/** Whether a referenced source is currently resolvable. */
enum CatalogReferenceAvailability
{
    notChecked, /// Availability has not been probed.
    available, /// The source resolves on disk and can be read.
    unavailable /// The source is known but cannot currently be resolved.
}

/** Lifecycle of one independently extracted metadata family. */
enum CatalogExtractorState
{
    notRequested, /// Extraction was not requested for this content.
    pending, /// Extraction was requested but has not finished.
    completed, /// Extraction finished with at least one result.
    empty, /// Extraction finished without findings.
    failed /// Extraction failed; see `CatalogExtractorStatus.error`.
}

/** Metadata extractor status without storage-specific status columns. */
struct CatalogExtractorStatus
{
    string extractor; /// Stable extractor family key.
    CatalogExtractorState state; /// Current result/state for this extractor.
    string error; /// Optional diagnostic for `CatalogExtractorState.failed`.
}

/** One algorithm-tagged digest; byte encoding is independent of JSON formats. */
struct CatalogDigest
{
    string algorithm; /// Canonical lowercase digest algorithm name.
    ubyte[] value; /// Raw digest bytes, independent of interchange encoding.
}

/** Size and available checksums used for content equality. */
struct CatalogContentFingerprint
{
    ulong size; /// Content length in bytes.
    CatalogDigest[] digests; /// Available content digests.
    bool complete; /// True only when the configured identity set is complete.
}

/** Media stream category exposed by a content snapshot. */
enum CatalogMediaKind
{
    image, /// Still-image stream.
    video, /// Video stream.
    audio, /// Audio stream.
    text /// Text or subtitle stream.
}

/** Storage-neutral projection of one parsed media stream. */
struct CatalogMediaStream
{
    CatalogMediaKind kind; /// Image, video, audio, or text/subtitle.
    int index; /// Stream index within its media kind.
    string language; /// Optional language tag.
    string format; /// Container/tool-independent format label.
    ulong width; /// Pixel width where applicable.
    ulong height; /// Pixel height where applicable.
    uint channels; /// Audio channel count where applicable.
    double frameRate; /// Frames per second where applicable.
    ulong bitRate; /// Bits per second where available.
    string duration; /// Human-readable duration supplied by the extractor.
}

/** Summary of archive indexing persisted with one content record. */
struct CatalogArchiveSummary
{
    bool indexKnown; /// False when archive extraction was not requested or failed.
    size_t entryCount; /// Number of names in the current archive index.
    size_t entriesWithCompleteFingerprints; /// Entries deeply inspected so far.
}

/** Torrent metadata retained independently of optional file-list detail. */
struct CatalogTorrentSummary
{
    string name; /// Torrent root/display name.
    string magnetUri; /// Magnet URI when present.
    ulong totalSize; /// Described payload size in bytes.
    bool isMultiFile; /// Whether the torrent describes multiple payload files.
    string infoHashHex; /// Info dictionary hash when persisted by the source.
    string announce; /// Primary announce tracker when available.
    ulong pieceLength; /// Piece length when available.
    ulong piecesCount; /// Number of content pieces when available.
    bool fileListAvailable; /// Whether detailed torrent paths can be queried.
}

/** Detached content metadata snapshot; references and entry pages are separate. */
struct CatalogContentSnapshot
{
    ContentId id; /// Source-scoped content identity.
    CatalogContentFingerprint fingerprint; /// Size and available digests.
    string fileType; /// Optional file signature.
    CatalogMediaStream[] mediaStreams; /// Requested media detail snapshot.
    CatalogExtractorStatus[] extractors; /// Per-extractor status snapshot.
    bool hasArchive; /// Whether archive metadata is available.
    bool hasTorrent; /// Whether torrent metadata is available.
    CatalogArchiveSummary archiveSummary; /// Optional archive-index summary.
    CatalogTorrentSummary torrentSummary; /// Optional torrent metadata summary.
}

/** Directory/file query filters shared by the JSON and SQL adapters.
 *
 * Selected media kinds use OR semantics, with `mediaNegated` inverting their
 * combined condition. File-type/archive/torrent selectors form a second OR
 * group. Path and availability filters combine with those groups using AND.
 */
struct CatalogFilter
{
    string pathText; /// Substring filter over root-relative paths.
    bool caseSensitive; /// Apply case-sensitive path matching.
    bool video; /// Require video media unless media is negated.
    bool audio; /// Require audio media unless media is negated.
    bool image; /// Require image media unless media is negated.
    bool text; /// Require text/subtitle media unless media is negated.
    bool mediaNegated; /// Invert the combined selected-media condition.
    bool fileType; /// Require file-type metadata.
    bool archive; /// Require archive metadata.
    bool torrent; /// Require torrent metadata.
    bool availableOnly; /// Restrict results to currently available references.
    bool includeArchiveMembers; /// Include indexed members in file queries.
}

/** Stable user-visible file order; path breaks ties for size sorts. */
enum CatalogSortOrder
{
    pathAscending, /// Root-relative paths in ascending order.
    pathDescending, /// Root-relative paths in descending order.
    sizeAscending, /// Content size ascending, path ascending to break ties.
    sizeDescending /// Content size descending, path ascending to break ties.
}

/** Query/page boundary. A cursor is bound to source, query, sort, and page size. */
struct CatalogPageRequest
{
    size_t limit = 250; /// Maximum entries returned; zero is invalid.
    CatalogPageCursor cursor; /// Opaque continuation, invalid for the first page.
}

/** Query immediate child directories under one parent. */
struct CatalogDirectoryQuery
{
    /// Default/invalid ID denotes the source root.
    DirectoryId parentId; /// Parent whose immediate children are requested.
    CatalogFilter filter; /// Optional source-neutral filters.
}

/** Query immediate file references under one directory. */
struct CatalogFileQuery
{
    /// Default/invalid ID denotes files immediately below the source root.
    DirectoryId directoryId; /// Directory whose immediate files are requested.
    CatalogFilter filter; /// Optional source-neutral filters.
    CatalogSortOrder sortOrder = CatalogSortOrder.pathAscending; /// Stable display order.
}

/** Directory row with logical IDs and root-relative paths only. */
struct CatalogDirectory
{
    DirectoryId id; /// Opaque source-scoped directory ID.
    DirectoryId parentId; /// Invalid for a root child.
    string name; /// One path component.
    string relativePath; /// Normalized path from the source root.
    size_t childDirectoryCount; /// Immediate visible child directories.
    size_t fileCount; /// Immediate matching file references.
    ulong aggregateSize; /// Aggregate size of matching descendant content.
}

/** Bounded root aggregates. */
struct CatalogRootSummary
{
    size_t childDirectoryCount; /// Immediate matching child directories.
    size_t fileReferenceCount; /// Matching file references below the root.
    ulong aggregateSize; /// Aggregate size of matching content references.
}

/** File/reference projection independent of database row identifiers. */
struct CatalogFile
{
    ReferenceId referenceId; /// Opaque identity of this address.
    ContentId contentId; /// Shared content identity at this address.
    DirectoryId directoryId; /// Parent directory in the source tree.
    ContentLocator locator; /// Structured location; never a display path.
    string name; /// Final display component.
    string relativePath; /// Normalized source-relative display path.
    ulong size; /// Content size in bytes.
    string modifiedAt; /// Observed modification timestamp, if available.
    CatalogReferenceAvailability availability; /// Current source availability.
    bool hasFileType; /// File-type metadata exists.
    bool hasMedia; /// One or more media streams exist.
    bool hasVideo; /// At least one video stream exists.
    bool hasAudio; /// At least one audio stream exists.
    bool hasImage; /// At least one image stream exists.
    bool hasText; /// At least one text/subtitle stream exists.
    bool hasArchive; /// Archive metadata exists.
    bool hasTorrent; /// Torrent metadata exists.
}

/** One detached page and bidirectional continuation state. */
struct CatalogDirectoryPage
{
    CatalogDirectory[] directories; /// Detached result rows.
    CatalogPageCursor nextCursor; /// Forward continuation.
    CatalogPageCursor previousCursor; /// Backward continuation.
    bool hasMore; /// Additional rows follow this page.
    bool hasPrevious; /// A prior page exists.
}

/** One page of immediate file references and continuation state. */
struct CatalogFilePage
{
    CatalogFile[] files; /// Detached result rows in display order.
    CatalogPageCursor nextCursor; /// Forward continuation.
    CatalogPageCursor previousCursor; /// Backward continuation.
    bool hasMore; /// Additional rows follow this page.
    bool hasPrevious; /// A prior page exists.
}

/** Query deduplicated content rows for table-oriented projections. */
struct CatalogContentQuery
{
    /**
     * Reference filters. `pathText` matches a root-relative path substring and
     * also accepts an exact base64 SHA-1 digest of the content.
     */
    CatalogFilter filter;
}

/** One deduplicated content row with representative reference details. */
struct CatalogContentRow
{
    ContentId id; /// Content identity shared by all references.
    string displayPath; /// Representative source-relative reference path.
    string displayName; /// Final component of `displayPath`.
    ulong size; /// Content size in bytes.
    size_t referenceCount; /// References sharing this content.
    CatalogContentFingerprint fingerprint; /// Known digests.
    CatalogReferenceAvailability availability; /// Representative availability.
    bool hasFileType; /// File-type metadata exists.
    bool hasMedia; /// One or more media streams exist.
    bool hasVideo; /// At least one video stream exists.
    bool hasAudio; /// At least one audio stream exists.
    bool hasImage; /// At least one image stream exists.
    bool hasText; /// At least one text/subtitle stream exists.
    bool hasArchive; /// Archive metadata exists.
    bool hasTorrent; /// Torrent metadata exists.
}

/** One bounded page of deduplicated content rows. */
struct CatalogContentPage
{
    CatalogContentRow[] rows; /// Detached rows in stable source content order.
    CatalogPageCursor nextCursor; /// Forward continuation.
    CatalogPageCursor previousCursor; /// Backward continuation.
    bool hasMore; /// Additional rows follow this page.
    bool hasPrevious; /// A prior page exists.
    size_t total; /// Total matching rows for the query.
}

/** Select optional detail families loaded with a content snapshot. */
struct CatalogDetailMask
{
    bool fingerprint; /// Include content digest details.
    bool fileType; /// Include the full file-type signature.
    bool media; /// Include typed media streams.
    bool archiveSummary; /// Include archive index state/summary.
    bool torrentSummary; /// Include torrent manifest summary.
}

/**
 * One archive-index row in the current catalog model.
 *
 * `contentId` is set when deep inspection linked the member to a content
 * record. Locatable members are exposed through `CatalogArchiveMember`; this
 * struct is the index/metadata view used for paged archive listings.
 */
struct CatalogArchiveEntry
{
    ArchiveEntryId id; /// Distinguishes duplicate-name occurrences.
    string name; /// Original archive member name for display.
    string relativePath; /// Normalized member path when it is safe to resolve.
    size_t index; /// Position in the container's current ordered index.
    size_t occurrence; /// Occurrence among duplicate normalized paths.
    bool isDirectory; /// True for an explicit directory entry.
    bool hasSafePath; /// False for absolute or traversal paths.
    ulong size; /// Uncompressed entry size.
    string modifiedAt; /// Entry timestamp when supplied by the format.
    CatalogContentFingerprint fingerprint; /// Deep-scan digest state/details.
    ContentId contentId; /// Content identity when deep inspection linked a blob.
}

/** Torrent descriptor only; it does not imply that the described file exists. */
struct CatalogTorrentManifestEntry
{
    string[] pathComponents; /// Path components relative to the torrent root.
    ulong size; /// Expected payload size in bytes.
}

/** One bounded page of current-format archive metadata. */
struct CatalogArchiveEntryPage
{
    CatalogArchiveEntry[] entries; /// Detached archive metadata rows.
    CatalogPageCursor nextCursor; /// Forward continuation.
    bool hasMore; /// Additional rows follow this page.
}

/** One locatable member reference owned by a filesystem archive reference. */
struct CatalogArchiveMember
{
    ReferenceId referenceId; /// Source-scoped identity of this archive occurrence.
    ContentId contentId; /// Deep-linked payload identity, invalid when not available.
    ContentLocator locator; /// Structured container-reference and entry identity.
    string name; /// Original entry name for display.
    string relativePath; /// Normalized member path within the container.
    ulong size; /// Known uncompressed size, zero if unavailable.
    string modifiedAt; /// Member timestamp when available.
    CatalogReferenceAvailability availability; /// Availability inherited from its container.
    CatalogContentFingerprint fingerprint; /// Deep checksums when available.
}

/** One bounded page of locatable members for a selected archive reference. */
struct CatalogArchiveMemberPage
{
    CatalogArchiveMember[] members; /// Detached member references.
    CatalogPageCursor nextCursor; /// Forward continuation.
    bool hasMore; /// Additional members follow this page.
}

/** One bounded page of torrent manifest descriptors. */
struct CatalogTorrentEntryPage
{
    CatalogTorrentManifestEntry[] entries; /// Detached torrent descriptors.
    CatalogPageCursor nextCursor; /// Forward continuation.
    bool hasMore; /// Additional rows follow this page.
}

/** Filtered subset request; the adapter owns format-specific serialization. */
struct CatalogSubsetQuery
{
    string pathPrefix; /// Optional normalized source-relative path prefix.
    CatalogFilter filter; /// Common file-reference filters.
}

/** Export encodings supported by the backend contract version. */
enum CatalogExportFormat
{
    jsonV3, /// Legacy selector retained for source compatibility; no longer writable.
    jsonV4, /// Legacy selector retained for source compatibility; no longer writable.
    jsonV5 /// Current JSON interchange format.
}

/** Output format and selection details for a filtered subset export. */
struct CatalogExportOptions
{
    CatalogExportFormat format = CatalogExportFormat.jsonV5; /// Requested output format.
    string outputPath; /// Explicit destination path.
    bool includeContentDetails = true; /// Include selected content metadata.
    bool includeArchiveEntries = true; /// Include archive index details.
    bool includeTorrentEntries = true; /// Include torrent manifest details.
    bool prettyJson = false; /// Indent the serialized JSON for human reading.
}

/** Counts and publication result of one subset export. */
struct CatalogExportResult
{
    size_t referencesExported; /// References included in the subset.
    size_t contentsExported; /// Unique content records included.
    string outputPath; /// Published destination.
    bool committed; /// True only after output publication succeeds.
}

/** Explicit description of the source selected when a backend is opened. */
struct CatalogSourceInfo
{
    OperationStorageMode storageMode; /// Explicit mode selected at open.
    string displayName; /// Human-facing source label; not an ID.
}

/** Persistence model exposed by one catalog backend. */
enum CatalogPersistence
{
    inMemoryDocument, ///< Operations modify a document buffer; saving is explicit.
    transactionalStore ///< Operations commit directly in the storage backend.
}

/** Optional behavior and call concurrency supported by one source implementation. */
struct CatalogBackendCapabilities
{
    OperationKind[] operations; /// Operations accepted by this source.
    bool supportsTreeQueries; /// Root, directory, and file-reference queries are available.
    /// Multiple read calls may be issued concurrently on this backend instance.
    bool supportsConcurrentReads;
    /// Reads may run while a mutating operation is in progress.
    bool supportsReadsDuringMutation;
    bool supportsFilteredExport; /// Can write filtered relationship-closed exports.
    bool supportsArchiveEntryQueries; /// Can page through archive metadata.
    bool supportsTorrentEntryQueries; /// Can page through torrent descriptors.
    bool supportsFirstClassArchiveReferences; /// Members are normal content references.
    CatalogPersistence persistence = CatalogPersistence.transactionalStore; ///< Mutation model.

    /** Whether this backend accepts the specified operation kind.
     *
     * Params:
     *     operation = Operation kind to look up.
     * Returns: `true` when `operation` appears in `operations`.
     */
    bool supports(OperationKind operation) const
    {
        foreach (supported; operations)
            if (supported == operation)
                return true;
        return false;
    }
}

/** Stable failure categories for opening/querying a backend contract. */
enum CatalogBackendErrorCode
{
    invalidTarget, ///< The target shape or source does not match the request.
    invalidIdentifier, ///< An unknown or foreign typed identity was supplied.
    invalidLocator, ///< A locator is malformed or not safe to resolve.
    invalidCursor, ///< A cursor belongs to another source, query, or page size.
    unsupportedOperation, ///< The adapter does not accept this operation kind.
    unsupportedFeature, ///< The feature is not available for this source.
    closed, ///< The backend or document session was already closed.
    backendFailure, ///< Storage/adapter work failed; see the message.
    writeConflict, ///< The stored source changed after it was loaded.
    cancelled ///< Cooperative cancellation stopped the work.
}

/** Typed error for catalog contract/open/query failures. */
class CatalogBackendException : Exception
{
    CatalogBackendErrorCode code; /// Stable category for this contract error.

    /// Construct a typed backend error with a diagnostic message.
    this(CatalogBackendErrorCode code, string message)
    {
        super(message);
        this.code = code;
    }
}
