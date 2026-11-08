/** Storage-neutral catalog query and operation contract.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.catalogbackend;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.string : split, startsWith;

import dosierarkivo.archive : archivePathMatchesText;
import dosierskanilo.membercontentcache : MemberContentLease;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.operations : AnalysisOperationRequest, MetadataOperationRequest,
    OperationControl, OperationKind, OperationResult, OperationState,
    OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryBlobPage,
    RepositoryBlobFlags, RepositoryDuplicateGroup, RepositoryInfo,
    RepositoryQueryOptions;

/** Opaque identity of one content record in one catalog source. */
struct ContentId
{
    /// Opaque adapter-issued token; non-empty for every valid identity.
    private string token;

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
    private string token;

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
    private string token;

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
    private string token;

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
    private size_t index;
    /// Page size this cursor was issued for; later requests must match it.
    private size_t pageSize;
    /// Source/query/sort binding used to reject foreign cursors.
    package(dosierskanilo) string queryToken;
    /// True only for continuation cursors returned by a backend.
    private bool valid;

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

/**
 * One explicit save/discard session over an in-memory catalog document.
 *
 * Only sources with `CatalogPersistence.inMemoryDocument` provide this view.
 * Applying an operation changes the document buffer and marks it modified;
 * `save` persists the buffer, `discard` reloads from storage. Stored vs.
 * in-memory mutations stay separate from transactional stores.
 *
 * Document sessions are intended for interactive edit/save workflows. Use the
 * batch operation API when a dry-run preview must leave the document untouched.
 */
interface CatalogDocument
{
    /** Whether the document buffer differs from its last loaded/saved state.
     *
     * Returns: `true` when unsaved changes are present.
     */
    bool modified() const;

    /** Adapter fingerprint captured at load time for conflict detection.
     *
     * Returns: The opaque fingerprint of the stored catalog.
     */
    string fingerprint() const;

    /** Suggested filesystem root for rooted tree queries over this document.
     *
     * Returns: A suggested root path; empty when none is known.
     */
    string suggestedFilesystemRoot();

    /** Bind or clear the filesystem root used by tree queries.
     *
     * Params:
     *     root = Root path to bind; empty clears the binding.
     */
    void bindFilesystemRoot(string root);

    /** Apply a scan and optional metadata/duplicate phase to the document buffer.
     *
     * Params:
     *     request = Scan request describing the source and phases.
     *     control = Cooperative operation control handle.
     * Returns: The operation result for the buffered scan.
     */
    OperationResult applyScan(ScanOperationRequest request,
        OperationControl control);

    /** Apply an analysis and optional metadata phase to the document buffer.
     *
     * Params:
     *     request = Analysis request describing the source and phases.
     *     control = Cooperative operation control handle.
     * Returns: The operation result for the buffered analysis.
     */
    OperationResult applyAnalysis(AnalysisOperationRequest request,
        OperationControl control);

    /**
     * Persist the in-memory buffer when the document is modified.
     *
     * Params:
     *   pretty = indent the serialized catalog for human reading.
     * Throws: `CatalogBackendException` with `writeConflict` when the stored
     *     file changed after loading, or `CatalogWriteException` when the
     *     streaming write and its recovery fallback both fail.
     */
    void save(bool pretty = false);

    /**
     * Discard unsaved changes and reload the stored catalog.
     *
     * Throws: `CatalogBackendException` with `backendFailure` when the stored
     *     catalog cannot be reloaded. The session stays open.
     */
    void discard();

    /**
     * Mark the session closed without saving or discarding.
     *
     * Later document calls throw `CatalogBackendException` with `closed`.
     */
    void close();
}

/** One source-bound, storage-neutral view over JSON or repository storage.
 *
 * Query results are detached value snapshots. Cursors are opaque, source- and
 * query-bound values; a committed mutation may invalidate them. `close()` is
 * called after any operation and its workers have completed.
 */
interface CatalogBackend
{
    /** The explicit target accepted by the factory that opened this backend.
     *
     * Returns: The source-bound operation target.
     */
    OperationTarget target();

    /** Storage-neutral source label and kind.
     *
     * Returns: The storage mode and a human-facing display label.
     */
    CatalogSourceInfo sourceInfo();

    /** Repository-style metadata for CLI info output.
     *
     * Returns: Repository root and schema metadata.
     */
    RepositoryInfo repositoryInfo();

    /** Supported operations/features; unsupported behavior is never inferred.
     *
     * Returns: The capability set advertised by this source.
     */
    CatalogBackendCapabilities capabilities();

    /**
     * Open the in-memory document view.
     *
     * Returns: A save/discard session over the document buffer.
     * Throws: `CatalogBackendException` with `unsupportedFeature` for
     *     transactional stores or when the adapter has no document session.
     */
    CatalogDocument document();

    /** Return bounded aggregates for the source root under the shared filter.
     *
     * Params:
     *     filter = Source-neutral filters applied to the aggregates.
     * Returns: Directory, reference, and aggregate-size totals.
     */
    CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init);

    /** List immediate child directories under the requested parent.
     *
     * Params:
     *     query = Parent directory and source-neutral filters.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded directory page with continuation state.
     */
    CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List matching immediate file references in the selected stable order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The requested file page.
     */
    CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Continue forward using a cursor issued for this source and query.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Forward continuation cursor returned for the same query.
     * Returns: The next file page.
     */
    CatalogFilePage nextFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /** Continue backward and return rows in the query's display order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Backward continuation cursor returned for the same query.
     * Returns: The preceding file page.
     */
    CatalogFilePage previousFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /**
     * Return a bounded page adjacent to a reference for stateless navigation.
     *
     * `anchorRelativePath` names a reference in the same directory and filter.
     * A forward page starts strictly after it; a backward page ends strictly
     * before it and returns the nearest matches in display order. An empty
     * anchor starts at the first file for forward requests and yields an empty
     * page otherwise. Unknown anchors yield an empty page so callers can drop
     * stale UI state instead of guessing a position.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     anchorRelativePath = Reference path to position next to; empty starts
     *         at the first file for forward requests.
     *     forward = Select rows after the anchor instead of before it.
     *     limit = Maximum rows to return; must be greater than zero.
     * Returns: The adjacent page, or an empty page for an unknown anchor.
     */
    CatalogFilePage listFilesFrom(CatalogFileQuery query, string anchorRelativePath,
        bool forward, size_t limit = 250);

    /** List deduplicated content rows for table-oriented projections.
     *
     * Params:
     *     query = Content filters applied by the backend.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded content page with total row count.
     */
    CatalogContentPage listContents(CatalogContentQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /**
     * Store or clear the archive password for one reference path.
     *
     * The path is resolved like `resolveReference`; a unique basename is also
     * accepted. An empty password clears the stored value. Unknown or ambiguous
     * paths raise `invalidIdentifier`, unsupported stores raise
     * `unsupportedFeature`.
     *
     * Params:
     *     relativePath = Reference path or unique basename to update.
     *     password = Password to store; empty clears the stored value.
     */
    void setArchivePassword(string relativePath, string password);

    /** Load one detached content snapshot, including only requested details.
     *
     * Params:
     *     contentId = Content identity to load.
     *     details = Detail families to include in the snapshot.
     * Returns: The requested content snapshot.
     */
    CatalogContentSnapshot loadContent(ContentId contentId,
        CatalogDetailMask details = CatalogDetailMask.init);

    /** Page through the current archive index for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed archive.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded archive-entry page.
     */
    CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List bounded, structured member references for one selected container reference.
     *
     * Params:
     *     containerReferenceId = Reference identity of the container.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded archive-member page.
     */
    CatalogArchiveMemberPage listArchiveMembers(ReferenceId containerReferenceId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Page through torrent manifest descriptors for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed torrent.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded torrent-entry page.
     */
    CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /**
     * Resolve a root-relative directory path to its typed identity.
     *
     * An empty path (or ".") denotes the source root and returns an invalid ID.
     * An unknown path also returns an invalid ID; callers must not treat
     * unresolved paths as errors during state restoration.
     *
     * Params:
     *     relativePath = Normalized source-relative directory path.
     * Returns: The matching identity, or an invalid ID when unresolved.
     */
    DirectoryId resolveDirectory(string relativePath);

    /**
     * Resolve a root-relative reference path to its typed identity.
     *
     * Canonical virtual member paths (`container!/member`) are accepted. An
     * unknown path returns an invalid ID.
     *
     * Params:
     *     relativePath = Normalized reference path.
     * Returns: The matching identity, or an invalid ID when unresolved.
     */
    ReferenceId resolveReference(string relativePath);

    /**
     * Load one reference row by typed identity.
     *
     * Params:
     *     referenceId = Reference identity to load.
     * Returns: The detached reference row.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the
     *     reference is unknown or belongs to another source.
     */
    CatalogFile loadReference(ReferenceId referenceId);

    /**
     * Extract one archive member through the process-wide leased cache.
     *
     * The backend resolves the container chain, looks up stored container
     * passwords, and returns a lease the caller must release. Extraction
     * failures surface as typed backend errors; cache capacity and close
     * failures are reported by the cache.
     *
     * Params:
     *     memberReferenceId = Reference identity of the archive member.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: A lease over the extracted member content.
     */
    MemberContentLease acquireMemberContent(ReferenceId memberReferenceId,
        shared(bool)* cancellation = null);

    /**
     * Opaque key for UI tree/list models.
     *
     * The value is stable while this backend instance is open, differs between
     * identifier kinds, and must never be parsed or persisted. Use
     * `resolveDirectory`/`resolveReference` to restore UI state by path.
     *
     * Params:
     *     id = Directory identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(DirectoryId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid directory identity.");
        return "dir:" ~ id.adapterToken;
    }

    /** Opaque reference key for UI models; see the directory overload.
     *
     * Params:
     *     id = Reference identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(ReferenceId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid reference identity.");
        return "ref:" ~ id.adapterToken;
    }

    /** Opaque content key for UI models; see the directory overload.
     *
     * Params:
     *     id = Content identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(ContentId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid content identity.");
        return "content:" ~ id.adapterToken;
    }

    /** Page through repository-style blob query results.
     *
     * Params:
     *     options = Query offsets, limits, filters, and sort options.
     * Returns: The repository blob page with ids and flags.
     */
    RepositoryBlobPage queryBlobs(RepositoryQueryOptions options);

    /** Return duplicate groups without mutating the source.
     *
     * Params:
     *     limit = Maximum groups requested; must be greater than zero.
     * Returns: The duplicate groups, or an empty array when none exist.
     */
    RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100);

    /** Export a selected relationship-closed subset to an explicit destination.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     * Returns: Counts and publication state of the export.
     */
    CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options);

    /**
     * Export a subset with cooperative cancellation. Implementations stop at
     * safe checkpoints and leave `committed` false when cancelled.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: Counts and publication state; `committed` is false when
     *     cancelled.
     */
    CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
        CatalogExportOptions options, OperationControl control,
        ulong operationId);

    /** Import a JSON catalog into the bound repository source.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     */
    void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init);

    /**
     * Import a JSON catalog with cooperative cancellation. Returns `false` when
     * the import was cancelled before commit.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: `true` when committed, `false` when cancelled before commit.
     */
    bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId);

    /** Run scan synchronously and require its explicit root to match this source.
     *
     * Params:
     *     request = Scan request including target and scan options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(ScanOperationRequest request,
        OperationControl control);

    /** Run metadata synchronously when supported and bound to this source.
     *
     * Params:
     *     request = Metadata request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control);

    /**
     * Run analysis synchronously when supported. JSON analysis may omit its
     * filesystem root; a supplied root must match the opened source.
     *
     * Params:
     *     request = Analysis request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control);

    /**
     * Release source resources after active operations have joined. Closing does
     * not mutate the catalog; subsequent calls report the typed `closed` error.
     */
    void close();
}

/** Explicit factory boundary; implementations select, but never reinterpret, a target. */
interface CatalogBackendFactory
{
    /**
     * Open exactly this target or throw a typed target/open error.
     *
     * JSON targets may omit the filesystem root for analysis-only use. Rooted
     * tree queries and scans require a root at open time or a later call to
     * `CatalogDocument.bindFilesystemRoot`.
     *
     * Params:
     *     target = Operation target to open.
     * Returns: A backend bound to the requested source.
     * Throws: `CatalogBackendException` when the target shape or source cannot
     *     be opened.
     */
    CatalogBackend open(OperationTarget target);
}

version (unittest)
{
    import std.algorithm.mutation : reverse;
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.conv : to;
    import std.path : baseName;
    import std.string : startsWith, toLower;
    import std.uuid : randomUUID;

    /** In-memory catalog backend used by the contract unittests.
     *
     * It exposes a small fixed tree and two content identities so query,
     * paging, and cursor behavior can be exercised without storage.
     */
    private class FakeCatalogBackend : CatalogBackend
    {
        /// Operation target this fake was opened with.
        private OperationTarget sourceTarget;
        /// Random per-instance token that scopes generated identities and cursors.
        private string instanceToken;
        /// Whether `close` has been called on this fake.
        private bool closed;
        /// Identity of the first fake content, shared by three file references.
        private ContentId contentOne;
        /// Identity of the second fake content, used by the image file.
        private ContentId contentTwo;
        /// Identity of fake directory `a`.
        private DirectoryId directoryA;
        /// Identity of fake directory `b`.
        private DirectoryId directoryB;
        /// Fixed file rows served by this fake.
        private CatalogFile[] files;
        /// Fixed directory rows served by this fake.
        private CatalogDirectory[] directories;

        /** Create the fixed fake data set for one operation target.
         *
         * Params:
         *     target = Operation target this fake reports and validates against.
         */
        this(OperationTarget target)
        {
            sourceTarget = target;
            instanceToken = randomUUID().toString();
            contentOne = ContentId(instanceToken ~ ":content-one");
            contentTwo = ContentId(instanceToken ~ ":content-two");
            directoryA = DirectoryId(instanceToken ~ ":directory-a");
            directoryB = DirectoryId(instanceToken ~ ":directory-b");

            const auto first = makeFile("a/one.txt", "reference-one", contentOne,
                directoryA, 10);
            const auto duplicate = makeFile("a/two-copy.txt", "reference-two",
                contentOne, directoryA, 10);
            const auto third = makeFile("a/three-copy.txt", "reference-three",
                contentOne, directoryA, 10);
            auto image = makeFile("b/photo.bmp", "reference-four", contentTwo,
                directoryB, 20);
            image.hasImage = true;
            image.hasMedia = true;
            image.hasArchive = true;
            files = [first, duplicate, third, image];

            CatalogDirectory a;
            a.id = directoryA;
            a.name = "a";
            a.relativePath = "a";
            a.fileCount = 3;
            a.aggregateSize = 30;
            CatalogDirectory b;
            b.id = directoryB;
            b.name = "b";
            b.relativePath = "b";
            b.fileCount = 1;
            b.aggregateSize = 20;
            directories = [a, b];
        }

        /** Reject calls made after this fake backend was closed.
         *
         * Throws: `CatalogBackendException` with `closed` when already closed.
         */
        private void requireOpen() const
        {
            if (closed)
                throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                    "Catalog backend is closed.");
        }

        /** Require an open backend that can serve rooted tree queries.
         *
         * Throws: `CatalogBackendException` with `closed` when closed, or
         *     `unsupportedFeature` for an unrooted JSON target.
         */
        private void requireTreeQueries() const
        {
            requireOpen();
            if (sourceTarget.mode == OperationStorageMode.jsonCatalog
                && sourceTarget.filesystemRoot.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "JSON tree queries require an explicit filesystem root.");
        }

        /** Validate that an operation target names this fake's source.
         *
         * Params:
         *     requestTarget = Target supplied by the operation request.
         *     operation = Operation kind; scan additionally requires a root.
         * Throws: `CatalogBackendException` with `closed` or `invalidTarget`.
         */
        private void requireTarget(OperationTarget requestTarget,
            OperationKind operation) const
        {
            requireOpen();
            bool matchesSource = requestTarget.mode == sourceTarget.mode;
            if (matchesSource && requestTarget.mode == OperationStorageMode.repository)
                matchesSource = requestTarget.repositoryRoot == sourceTarget.repositoryRoot;
            else if (matchesSource)
            {
                matchesSource = requestTarget.catalogPath == sourceTarget.catalogPath;
                if (matchesSource && requestTarget.filesystemRoot.length > 0)
                    matchesSource = requestTarget.filesystemRoot
                        == sourceTarget.filesystemRoot;
                if (matchesSource && operation == OperationKind.scan)
                    matchesSource = requestTarget.filesystemRoot.length > 0
                        && requestTarget.filesystemRoot == sourceTarget.filesystemRoot;
            }
            if (!matchesSource)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidTarget,
                    "Operation target does not match the opened catalog source.");
        }

        /** Build one fake file row with a source-scoped reference identity.
         *
         * Params:
         *     path = Normalized source-relative file path.
         *     referenceToken = Per-instance suffix for the reference identity.
         *     contentId = Content identity shared by the row.
         *     parent = Parent directory identity.
         *     size = Content size in bytes.
         * Returns: The populated file row.
         * Throws: `CatalogBackendException` with `invalidLocator` for an
         *     unsafe path.
         */
        private CatalogFile makeFile(string path, string referenceToken,
            ContentId contentId, DirectoryId parent, ulong size)
        {
            CatalogFile file;
            file.referenceId = ReferenceId(instanceToken ~ ":" ~ referenceToken);
            file.contentId = contentId;
            file.directoryId = parent;
            file.locator = ContentLocator.file(path);
            file.name = baseName(path);
            file.relativePath = path;
            file.size = size;
            file.availability = CatalogReferenceAvailability.available;
            return file;
        }

        /** Return whether a fake file row satisfies all filter groups.
         *
         * Params:
         *     file = Row to test.
         *     filter = Source-neutral filters to apply.
         * Returns: `true` when the row matches.
         */
        private bool matches(CatalogFile file, CatalogFilter filter) const
        {
            if (filter.pathText.length > 0
                && !archivePathMatchesText(file.relativePath, filter.pathText,
                    filter.caseSensitive))
                return false;
            if (filter.availableOnly
                && file.availability != CatalogReferenceAvailability.available)
                return false;
            const bool selectedMedia = filter.video || filter.audio || filter.image
                || filter.text;
            if (selectedMedia)
            {
                const bool hasSelectedMedia = (filter.video && file.hasVideo)
                    || (filter.audio && file.hasAudio)
                    || (filter.image && file.hasImage)
                    || (filter.text && file.hasText);
                if (filter.mediaNegated ? hasSelectedMedia : !hasSelectedMedia)
                    return false;
            }
            const bool hasTypeFilter = filter.fileType || filter.archive
                || filter.torrent;
            const bool matchesType = (filter.fileType && file.hasFileType)
                || (filter.archive && file.hasArchive)
                || (filter.torrent && file.hasTorrent);
            if (hasTypeFilter && !matchesType)
                return false;
            return true;
        }

        /** Return query matches in the requested stable sort order.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         * Returns: Matching file rows, including archive members when asked.
         */
        private CatalogFile[] filteredFiles(CatalogFileQuery query) const
        {
            CatalogFile[] result;
            foreach (file; files)
                if (file.directoryId == query.directoryId
                    && matches(file, query.filter))
                    result ~= file;
            if (query.filter.includeArchiveMembers)
                foreach (container; files)
                    if (container.directoryId == query.directoryId
                        && container.hasArchive)
                        foreach (member; archiveMembersFor(container))
                            if (matches(member, query.filter))
                                result ~= member;
            if (query.sortOrder == CatalogSortOrder.pathDescending)
                result.reverse;
            else if (query.sortOrder == CatalogSortOrder.sizeAscending)
                result.sort!((left, right) => left.size < right.size
                    || (left.size == right.size
                        && left.relativePath < right.relativePath));
            else if (query.sortOrder == CatalogSortOrder.sizeDescending)
                result.sort!((left, right) => left.size > right.size
                    || (left.size == right.size
                        && left.relativePath < right.relativePath));
            return result;
        }

        /** Build the source binding token embedded in issued cursors.
         *
         * Returns: A token encoding the instance and opened target.
         */
        private string sourceToken() const
        {
            return instanceToken ~ "\0" ~ (cast(int) sourceTarget.mode).to!string ~ "\0"
                ~ sourceTarget.repositoryRoot ~ "\0" ~ sourceTarget.catalogPath
                ~ "\0" ~ sourceTarget.filesystemRoot;
        }

        /** Serialize filter flags into a stable cursor-binding token.
         *
         * Params:
         *     filter = Filters to encode.
         * Returns: A delimiter-joined token that changes with every flag.
         */
        private string filterToken(CatalogFilter filter) const
        {
            return filter.pathText ~ "\0" ~ (filter.caseSensitive ? "1" : "0")
                ~ (filter.video ? "1" : "0") ~ (filter.audio ? "1" : "0")
                ~ (filter.image ? "1" : "0") ~ (filter.text ? "1" : "0")
                ~ (filter.mediaNegated ? "1" : "0") ~ (filter.fileType ? "1" : "0")
                ~ (filter.archive ? "1" : "0") ~ (filter.torrent ? "1" : "0")
                ~ (filter.availableOnly ? "1" : "0")
                ~ (filter.includeArchiveMembers ? "1" : "0");
        }

        /** Build the single fake archive member row for a container.
         *
         * Params:
         *     container = Archive reference that owns the member.
         * Returns: A one-element array holding the member row.
         */
        private CatalogFile[] archiveMembersFor(CatalogFile container) const
        {
            auto entryId = ArchiveEntryId(instanceToken ~ ":archive-entry-one");
            CatalogFile member;
            member.referenceId = ReferenceId(instanceToken
                ~ ":archive-reference:" ~ container.referenceId.adapterToken
                ~ ":" ~ entryId.adapterToken);
            member.contentId = contentOne;
            member.directoryId = container.directoryId;
            member.locator = ContentLocator.entry(container.referenceId, entryId);
            member.name = "readme.txt";
            member.relativePath = container.relativePath ~ "!/nested/readme.txt";
            member.size = 10;
            member.availability = container.availability;
            return [member];
        }

        /** Build the cursor query binding for a file query.
         *
         * Params:
         *     query = Query whose directory, filter, and sort are encoded.
         * Returns: A token bound to this fake source and query.
         */
        private string fileQueryToken(CatalogFileQuery query) const
        {
            return sourceToken() ~ "\0file\0" ~ query.directoryId.token ~ "\0"
                ~ filterToken(query.filter) ~ "\0"
                ~ (cast(int) query.sortOrder).to!string;
        }

        /** Build the cursor query binding for a directory query.
         *
         * Params:
         *     query = Query whose parent and filter are encoded.
         * Returns: A token bound to this fake source and query.
         */
        private string directoryQueryToken(CatalogDirectoryQuery query) const
        {
            return sourceToken() ~ "\0directory\0" ~ query.parentId.token
                ~ "\0" ~ filterToken(query.filter);
        }

        /** Load one file page and its continuation cursors from the fake data.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The detached page with forward/backward cursors.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `invalidCursor` for a zero limit, or a cursor bound to another
         *     source/query/page size.
         */
        private CatalogFilePage filePage(CatalogFileQuery query,
            CatalogPageRequest page)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            auto all = filteredFiles(query);
            auto start = page.cursor.isValid ? page.cursor.index : 0;
            if (page.cursor.isValid
                && page.cursor.queryToken != fileQueryToken(query))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor belongs to a different source or query.");
            if (start > all.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor is outside this query result.");
            if (page.cursor.isValid && page.limit != page.cursor.pageSize)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor page size does not match this request.");
            auto end = start + page.limit;
            if (end > all.length)
                end = all.length;
            CatalogFilePage result;
            result.files = all[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(
                    start > page.limit ? start - page.limit : 0, page.limit,
                    fileQueryToken(query));
            result.hasMore = end < all.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit,
                    fileQueryToken(query));
            return result;
        }

        /** Collapse fake file rows into deduplicated content rows.
         *
         * Params:
         *     query = Content filters; matching references select a row.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The bounded content page with continuation state.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogContentPage listContents(CatalogContentQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            const auto queryToken = "contents\0" ~ filterToken(query.filter);
            if (page.cursor.isValid)
            {
                if (page.cursor.adapterQueryToken != queryToken
                    || page.limit != page.cursor.adapterPageSize)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidCursor,
                        "Catalog cursor belongs to a different query or page size.");
            }

            CatalogContentRow[] all;
            size_t[string] indexByContent;
            foreach (file; files)
            {
                const token = file.contentId.adapterToken;
                auto index = token in indexByContent;
                if (index is null)
                {
                    CatalogContentRow row;
                    row.id = file.contentId;
                    row.displayPath = file.relativePath;
                    row.displayName = file.name;
                    row.size = file.size;
                    row.referenceCount = 1;
                    row.availability = file.availability;
                    row.hasFileType = file.hasFileType;
                    row.hasMedia = file.hasMedia;
                    row.hasVideo = file.hasVideo;
                    row.hasAudio = file.hasAudio;
                    row.hasImage = file.hasImage;
                    row.hasText = file.hasText;
                    row.hasArchive = file.hasArchive;
                    row.hasTorrent = file.hasTorrent;
                    indexByContent[token] = all.length;
                    all ~= row;
                    continue;
                }
                auto row = &all[*index];
                ++row.referenceCount;
                if (file.relativePath < row.displayPath)
                {
                    row.displayPath = file.relativePath;
                    row.displayName = file.name;
                }
                row.hasFileType = row.hasFileType || file.hasFileType;
                row.hasMedia = row.hasMedia || file.hasMedia;
                row.hasVideo = row.hasVideo || file.hasVideo;
                row.hasAudio = row.hasAudio || file.hasAudio;
                row.hasImage = row.hasImage || file.hasImage;
                row.hasText = row.hasText || file.hasText;
                row.hasArchive = row.hasArchive || file.hasArchive;
                row.hasTorrent = row.hasTorrent || file.hasTorrent;
            }

            CatalogContentRow[] matching;
            foreach (row; all)
            {
                bool pathMatch;
                foreach (file; files)
                {
                    if (file.contentId != row.id)
                        continue;
                    if (matches(file, query.filter))
                    {
                        pathMatch = true;
                        break;
                    }
                }
                if (pathMatch)
                    matching ~= row;
            }
            const auto start = page.cursor.isValid ? page.cursor.adapterIndex : 0;
            if (start > matching.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor is outside this query result.");
            const auto end = start + page.limit < matching.length
                ? start + page.limit : matching.length;
            CatalogContentPage result;
            result.rows = matching[start .. end];
            result.total = matching.length;
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(start > page.limit
                    ? start - page.limit : 0, page.limit, queryToken);
            result.hasMore = end < matching.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit, queryToken);
            return result;
        }

        /// Stored archive passwords keyed by reference path.
        private string[string] archivePasswords;

        /** Store or clear a fake archive password by reference path.
         *
         * Params:
         *     relativePath = Exact path or unique basename of the reference.
         *     password = Password to store; empty clears the stored value.
         * Throws: `CatalogBackendException` with `closed`, `invalidIdentifier`
         *     for an unknown or ambiguous path.
         */
        override void setArchivePassword(string relativePath, string password)
        {
            requireOpen();
            size_t[] exact;
            size_t[] byName;
            foreach (index, file; files)
                if (file.relativePath == relativePath)
                    exact ~= index;
                else if (baseName(file.relativePath) == relativePath
                    && baseName(relativePath) == relativePath)
                    byName ~= index;
            const auto matches = exact.length > 0 ? exact : byName;
            if (matches.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "No catalog reference matches the requested path.");
            if (matches.length > 1)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "The requested filename is ambiguous in this catalog.");
            if (password.length == 0)
                archivePasswords.remove(files[matches[0]].relativePath);
            else
                archivePasswords[files[matches[0]].relativePath] = password;
        }

        /** Reject the document view; the fake is a transactional store.
         *
         * Returns: Never returns; this fake always throws.
         * Throws: `CatalogBackendException` with `unsupportedFeature`.
         */
        override CatalogDocument document()
        {
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "The contract fake has no in-memory document view.");
        }

        /** Return the target this fake was opened with.
         *
         * Returns: The stored operation target.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override OperationTarget target()
        {
            requireOpen();
            return sourceTarget;
        }

        /** Return the fake source label and storage mode.
         *
         * Returns: Storage mode from the target and a display label.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override CatalogSourceInfo sourceInfo()
        {
            requireOpen();
            CatalogSourceInfo result;
            result.storageMode = sourceTarget.mode;
            result.displayName = sourceTarget.mode == OperationStorageMode.jsonCatalog
                ? sourceTarget.catalogPath : "in-memory repository";
            return result;
        }

        /** Return minimal repository-style metadata for the fake source.
         *
         * Returns: A synthetic repository root and schema version.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override RepositoryInfo repositoryInfo()
        {
            requireOpen();
            RepositoryInfo result;
            result.rootPath = sourceTarget.mode == OperationStorageMode.repository
                ? sourceTarget.repositoryRoot : sourceTarget.catalogPath;
            result.schemaVersion = sourceTarget.mode == OperationStorageMode.repository ? 4 : 5;
            return result;
        }

        /** Return the capabilities advertised by the fake backend.
         *
         * Returns: Tree-query, export, archive, and torrent features for the
         *     fixed data set.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override CatalogBackendCapabilities capabilities()
        {
            requireOpen();
            CatalogBackendCapabilities result;
            result.supportsTreeQueries = sourceTarget.mode == OperationStorageMode.repository
                || sourceTarget.filesystemRoot.length > 0;
            result.operations = [OperationKind.analyze];
            if (result.supportsTreeQueries)
                result.operations ~= OperationKind.scan;
            result.supportsConcurrentReads = true;
            result.supportsReadsDuringMutation = true;
            result.supportsFilteredExport = result.supportsTreeQueries;
            result.supportsArchiveEntryQueries = true;
            result.supportsTorrentEntryQueries = true;
            result.supportsFirstClassArchiveReferences = true;
            result.persistence = CatalogPersistence.transactionalStore;
            return result;
        }

        /** Aggregate fake root rows under the given filter.
         *
         * Params:
         *     filter = Source-neutral filters; archive members may be included.
         * Returns: Directory, reference, and aggregate-size totals.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init)
        {
            requireTreeQueries();
            CatalogRootSummary result;
            result.childDirectoryCount = directories.length;
            foreach (file; files)
                if (matches(file, filter))
                {
                    result.fileReferenceCount++;
                    result.aggregateSize += file.size;
                }
            if (filter.includeArchiveMembers)
                foreach (container; files)
                    if (container.hasArchive)
                        foreach (member; archiveMembersFor(container))
                            if (matches(member, filter))
                            {
                                ++result.fileReferenceCount;
                                result.aggregateSize += member.size;
                            }
            return result;
        }

        /** Page through the fixed fake directory rows.
         *
         * Params:
         *     query = Parent directory whose immediate children are requested.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The bounded directory page with continuation state.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            CatalogDirectory[] matching;
            foreach (directory; directories)
                if (directory.parentId == query.parentId)
                    matching ~= directory;
            auto start = page.cursor.isValid ? page.cursor.index : 0;
            if (start > matching.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor is outside this query result.");
            if (page.cursor.isValid
                && page.cursor.queryToken != directoryQueryToken(query))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor belongs to a different source or query.");
            if (page.cursor.isValid && page.limit != page.cursor.pageSize)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor page size does not match this request.");
            auto end = start + page.limit;
            if (end > matching.length)
                end = matching.length;
            CatalogDirectoryPage result;
            result.directories = matching[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(
                    start > page.limit ? start - page.limit : 0, page.limit,
                    directoryQueryToken(query));
            result.hasMore = end < matching.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit,
                    directoryQueryToken(query));
            return result;
        }

        /** Page through fake file references from the first page.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The requested file page.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage listFiles(CatalogFileQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            return filePage(query, page);
        }

        /** Continue forward from a fake file cursor.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     cursor = Cursor returned by this fake for the same query.
         * Returns: The next file page.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage nextFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

        /** Return the fake page before a file cursor.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     cursor = Cursor returned by this fake for the same query.
         * Returns: The preceding file page in display order.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage previousFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

        /** Load a fake page adjacent to an anchor file path.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     anchorRelativePath = Anchor path; empty starts at the first file.
         *     forward = Select rows after the anchor instead of before it.
         *     limit = Maximum rows to return; must be greater than zero.
         * Returns: The adjacent page, or an empty page for an unknown anchor.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor` for a zero limit.
         */
        override CatalogFilePage listFilesFrom(CatalogFileQuery query,
            string anchorRelativePath, bool forward, size_t limit = 250)
        {
            requireTreeQueries();
            if (limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            auto all = filteredFiles(query);
            if (anchorRelativePath.length == 0)
            {
                if (!forward || all.length == 0)
                    return CatalogFilePage.init;
                CatalogFilePage result;
                const auto end = limit < all.length ? limit : all.length;
                result.files = all[0 .. end];
                result.hasMore = end < all.length;
                if (result.hasMore)
                    result.nextCursor = CatalogPageCursor(end, limit,
                        fileQueryToken(query));
                return result;
            }
            size_t anchor = size_t.max;
            foreach (index, file; all)
                if (file.relativePath == anchorRelativePath)
                {
                    anchor = index;
                    break;
                }
            if (anchor == size_t.max)
                return CatalogFilePage.init;
            const size_t start = forward ? anchor + 1
                : (anchor > limit ? anchor - limit : 0);
            const size_t end = forward
                ? (start + limit < all.length ? start + limit : all.length)
                : anchor;
            CatalogFilePage result;
            result.files = all[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(start > limit
                    ? start - limit : 0, limit, fileQueryToken(query));
            result.hasMore = forward ? end < all.length : anchor < all.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, limit,
                    fileQueryToken(query));
            return result;
        }

        /** Load a fake content snapshot for one of the two known contents.
         *
         * Params:
         *     contentId = Content identity issued by this fake.
         *     details = Detail families to include in the snapshot.
         * Returns: The requested content snapshot.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogContentSnapshot loadContent(ContentId contentId,
            CatalogDetailMask details = CatalogDetailMask.init)
        {
            requireOpen();
            if (contentId != contentOne && contentId != contentTwo)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown content identity.");
            CatalogContentSnapshot result;
            result.id = contentId;
            result.fingerprint.size = contentId == contentOne ? 10 : 20;
            result.fingerprint.complete = true;
            if (contentId == contentOne)
            {
                result.hasTorrent = true;
                result.torrentSummary.name = "payload.torrent";
                result.torrentSummary.totalSize = 10;
                result.torrentSummary.fileListAvailable = true;
            }
            else
            {
                result.hasArchive = true;
                result.archiveSummary.indexKnown = true;
                result.archiveSummary.entryCount = 1;
            }
            return result;
        }

        /** Page through fake archive entries for the archive content.
         *
         * Params:
         *     contentId = Content identity; only the archive content is accepted.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One entry on the first page, otherwise an empty page.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireOpen();
            if (contentId != contentTwo)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Content is not an indexed archive.");
            CatalogArchiveEntryPage result;
            if (!page.cursor.isValid || page.cursor.index == 0)
            {
                CatalogArchiveEntry entry;
                entry.id = ArchiveEntryId(instanceToken ~ ":archive-entry-one");
                entry.name = "nested/readme.txt";
                entry.size = 10;
                result.entries = [entry];
            }
            return result;
        }

        /** Return fake member references for an archive container.
         *
         * Params:
         *     containerReferenceId = Reference identity of an archive container.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One member on the first page, otherwise an empty page.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `invalidIdentifier`, or `invalidCursor`.
         */
        override CatalogArchiveMemberPage listArchiveMembers(
            ReferenceId containerReferenceId, CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (!containerReferenceId.isValid || page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Archive member query requires a valid container reference and page.");
            CatalogFile container;
            foreach (file; files)
                if (file.referenceId == containerReferenceId)
                    container = file;
            if (!container.referenceId.isValid || !container.hasArchive)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Reference is not an indexed archive container.");
            const auto queryToken = sourceToken() ~ "\0archive-members\0"
                ~ containerReferenceId.adapterToken;
            if (page.cursor.isValid
                && (page.cursor.adapterQueryToken != queryToken
                    || page.cursor.adapterPageSize != page.limit))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Archive member cursor does not match this source or query.");
            const auto start = page.cursor.isValid
                ? page.cursor.adapterIndex : 0;
            if (start > 1)
                throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                    "Archive member cursor is outside the result sequence.");
            CatalogArchiveMemberPage result;
            if (start == 0)
            {
                auto entryId = ArchiveEntryId(instanceToken
                    ~ ":archive-entry-one");
                CatalogArchiveMember member;
                member.referenceId = ReferenceId(instanceToken
                    ~ ":archive-reference:" ~ containerReferenceId.adapterToken
                    ~ ":" ~ entryId.adapterToken);
                member.contentId = contentOne;
                member.locator = ContentLocator.entry(containerReferenceId, entryId);
                member.name = "readme.txt";
                member.relativePath = "nested/readme.txt";
                member.size = 10;
                member.availability = container.availability;
                member.fingerprint.size = 10;
                member.fingerprint.complete = true;
                result.members = [member];
            }
            return result;
        }

        /** Return fake torrent manifest rows for the torrent content.
         *
         * Params:
         *     contentId = Content identity; only the torrent content is accepted.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One manifest entry on the first page.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireOpen();
            if (contentId != contentOne)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Content is not an indexed torrent.");
            CatalogTorrentEntryPage result;
            if (!page.cursor.isValid || page.cursor.index == 0)
                result.entries = [CatalogTorrentManifestEntry(["payload.bin"], 10)];
            return result;
        }

        /** Resolve a fake directory path to its identity.
         *
         * Params:
         *     relativePath = Normalized path; empty or "." denotes the root.
         * Returns: The matching identity, or an invalid ID when unresolved.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override DirectoryId resolveDirectory(string relativePath)
        {
            requireTreeQueries();
            if (relativePath.length == 0 || relativePath == ".")
                return DirectoryId.init;
            foreach (directory; directories)
                if (directory.relativePath == relativePath)
                    return directory.id;
            return DirectoryId.init;
        }

        /** Resolve a fake file or archive-member path to its identity.
         *
         * Params:
         *     relativePath = Normalized reference path, including virtual
         *         member paths.
         * Returns: The matching identity, or an invalid ID when unresolved.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override ReferenceId resolveReference(string relativePath)
        {
            requireTreeQueries();
            foreach (file; files)
                if (file.relativePath == relativePath)
                    return file.referenceId;
            foreach (container; files)
                if (container.hasArchive)
                    foreach (member; archiveMembersFor(container))
                        if (member.relativePath == relativePath)
                            return member.referenceId;
            return ReferenceId.init;
        }

        /** Load a fake file or archive-member reference row.
         *
         * Params:
         *     referenceId = Reference identity issued by this fake.
         * Returns: The matching detached reference row.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `closed`, or `invalidIdentifier` for an unknown identity.
         */
        override CatalogFile loadReference(ReferenceId referenceId)
        {
            requireTreeQueries();
            foreach (file; files)
                if (file.referenceId == referenceId)
                    return file;
            foreach (container; files)
                if (container.hasArchive)
                    foreach (member; archiveMembersFor(container))
                        if (member.referenceId == referenceId)
                            return member;
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Unknown reference identity.");
        }

        /** Reject member extraction; the fake has no physical content.
         *
         * Params:
         *     memberReferenceId = Identity whose content is requested.
         *     cancellation = Optional cooperative cancellation flag.
         * Returns: Never returns; this fake always throws.
         * Throws: `CatalogBackendException` with `unsupportedFeature`.
         */
        override MemberContentLease acquireMemberContent(
            ReferenceId memberReferenceId, shared(bool)* cancellation = null)
        {
            requireTreeQueries();
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "The in-memory contract test backend cannot extract members.");
        }

        /** Return one synthetic repository blob page.
         *
         * Params:
         *     options = Query options; `limit` must be greater than zero.
         * Returns: A page with one blob and its flags.
         * Throws: `Exception` when `options.limit` is not positive.
         */
        override RepositoryBlobPage queryBlobs(RepositoryQueryOptions options)
        {
            enforce(options.limit > 0);
            RepositoryBlobPage result;
            result.total = 1;
            result.blobIds = [1];
            result.blobs = [new NamedBinaryBlob([new FileSpec("alpha.txt", "")], 10)];
            result.flags = [RepositoryBlobFlags(true, false, false, false, false,
                false, false, false)];
            return result;
        }

        /** Return one synthetic duplicate group.
         *
         * Params:
         *     limit = Maximum groups requested; must be greater than zero.
         * Returns: A single group with a fixed size and blob list.
         * Throws: `Exception` when `limit` is zero.
         */
        override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
        {
            enforce(limit > 0);
            return [RepositoryDuplicateGroup(10, [1])];
        }

        /** Acknowledge a fake subset export request.
         *
         * Params:
         *     query = Selected path prefix and filters.
         *     options = Output format and destination details.
         *     control = Unused cooperative control handle.
         *     operationId = Unused operation identifier.
         * Returns: The counted export result from `exportSubset`.
         */
        override CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
            CatalogExportOptions options, OperationControl control,
            ulong operationId)
        {
            return exportSubset(query, options);
        }

        /** Count fake subset matches without writing an output file.
         *
         * Params:
         *     query = Selected path prefix and filters.
         *     options = Output options; `outputPath` must not be empty.
         * Returns: Counts for the matching references and contents.
         * Throws: `CatalogBackendException` with `closed`,
         *     `unsupportedFeature`, or `invalidTarget`.
         */
        override CatalogExportResult exportSubset(CatalogSubsetQuery query,
            CatalogExportOptions options)
        {
            requireOpen();
            if (!capabilities().supportsFilteredExport)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "Filtered export requires a rooted catalog source.");
            if (options.outputPath.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidTarget,
                    "An explicit subset export path is required.");
            bool[string] contentIds;
            CatalogExportResult result;
            result.outputPath = options.outputPath;
            foreach (file; files)
            {
                const bool inPrefix = query.pathPrefix.length == 0
                    || file.relativePath == query.pathPrefix
                    || file.relativePath.startsWith(query.pathPrefix ~ "/");
                if (!inPrefix || !matches(file, query.filter))
                    continue;
                result.referencesExported++;
                contentIds[file.contentId.token] = true;
            }
            result.contentsExported = contentIds.length;
            result.committed = true;
            return result;
        }

        /** Accept and ignore a JSON import request.
         *
         * Params:
         *     jsonPath = Source path; must not be empty (asserted).
         *     options = Import options, intentionally unused.
         * Throws: `CatalogBackendException` with `closed`; `AssertError` for an
         *     empty path.
         */
        override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
        {
            requireOpen();
            assert(jsonPath.length > 0);
            cast(void) options;
        }

        /** Delegate a controlled JSON import to `importJson`.
         *
         * Params:
         *     jsonPath = Source path forwarded to `importJson`.
         *     options = Import options forwarded to `importJson`.
         *     control = Unused cooperative control handle.
         *     operationId = Unused operation identifier.
         * Returns: Always `true`; the fake cannot be cancelled.
         * Throws: `CatalogBackendException` with `closed`; `AssertError` for an
         *     empty path.
         */
        override bool importJsonControlled(string jsonPath,
            JsonImportOptions options, OperationControl control,
            ulong operationId)
        {
            importJson(jsonPath, options);
            return true;
        }

        /** Return a completed fake scan result for a matching target.
         *
         * Params:
         *     request = Scan request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result reporting all fake files as added.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(ScanOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.scan);
            requireSupported(OperationKind.scan);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.scan;
            result.state = OperationState.completed;
            result.changesCommitted = true;
            result.scanSummary.filesFound = files.length;
            result.scanSummary.filesAdded = files.length;
            return result;
        }

        /** Return a completed fake metadata result for a matching target.
         *
         * Params:
         *     request = Metadata request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result without summary changes.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(MetadataOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.metadata);
            requireSupported(OperationKind.metadata);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.metadata;
            result.state = OperationState.completed;
            return result;
        }

        /** Return a completed fake analysis result for a matching target.
         *
         * Params:
         *     request = Analysis request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result that reports committed changes.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(AnalysisOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.analyze);
            requireSupported(OperationKind.analyze);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.analyze;
            result.state = OperationState.completed;
            result.changesCommitted = true;
            return result;
        }

        /// Mark this fake backend closed; repeated calls have no effect.
        override void close()
        {
            closed = true;
        }

        /** Reject operations not advertised by `capabilities`.
         *
         * Params:
         *     operation = Operation kind to check.
         * Throws: `CatalogBackendException` with `unsupportedOperation`.
         */
        private void requireSupported(OperationKind operation)
        {
            if (!capabilities().supports(operation))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedOperation,
                    "The opened source does not support this operation.");
        }
    }

    /** Factory that opens `FakeCatalogBackend` instances for valid targets. */
    private class FakeCatalogBackendFactory : CatalogBackendFactory
    {
        /** Validate and open a fake backend for the requested target.
         *
         * Params:
         *     target = Repository or JSON target; the relevant root/path must
         *         not be empty.
         * Returns: A new fake backend bound to `target`.
         * Throws: `CatalogBackendException` with `invalidTarget` for an empty
         *     repository root or catalog path.
         */
        override CatalogBackend open(OperationTarget target)
        {
            final switch (target.mode)
            {
            case OperationStorageMode.repository:
                if (target.repositoryRoot.length == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidTarget,
                        "A repository target requires a root.");
                break;
            case OperationStorageMode.jsonCatalog:
                if (target.catalogPath.length == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidTarget,
                        "A JSON target requires a catalog path.");
                break;
            }
            return new FakeCatalogBackend(target);
        }
    }

    @("catalog backend contract exposes storage-neutral bounded queries and operations")
    unittest
    {
        bool rejectedAbsoluteLocator;
        try
        {
            const auto unexpectedLocator = ContentLocator.file("/outside/source.txt");
            rejectedAbsoluteLocator = unexpectedLocator.kind == ContentLocator.Kind.none;
        }
        catch (CatalogBackendException failure)
            rejectedAbsoluteLocator = failure.code
                == CatalogBackendErrorCode.invalidLocator;
        assert(rejectedAbsoluteLocator);

        bool rejectedTraversalLocator;
        try
        {
            const auto unexpectedLocator = ContentLocator.file("nested/../outside.txt");
            rejectedTraversalLocator = unexpectedLocator.kind == ContentLocator.Kind.none;
        }
        catch (CatalogBackendException failure)
            rejectedTraversalLocator = failure.code
                == CatalogBackendErrorCode.invalidLocator;
        assert(rejectedTraversalLocator);

        auto factory = new FakeCatalogBackendFactory();
        bool rejectedEmptyTarget;
        try
        {
            auto unexpectedBackend = factory.open(OperationTarget.init);
            rejectedEmptyTarget = unexpectedBackend.target().repositoryRoot.length > 0;
        }
        catch (CatalogBackendException failure)
            rejectedEmptyTarget = failure.code
                == CatalogBackendErrorCode.invalidTarget;
        assert(rejectedEmptyTarget);

        auto target = OperationTarget.jsonTarget("library.json", "/library");
        auto analysisOnlyTarget = OperationTarget.jsonTarget("library.json");
        auto analysisOnlyBackend = factory.open(analysisOnlyTarget);
        assert(!analysisOnlyBackend.capabilities().supportsTreeQueries);
        assert(analysisOnlyBackend.capabilities().supports(OperationKind.analyze));
        assert(!analysisOnlyBackend.capabilities().supports(OperationKind.scan));
        AnalysisOperationRequest analysisOnlyRequest;
        analysisOnlyRequest.operationId = 40;
        analysisOnlyRequest.target = analysisOnlyTarget;
        assert(analysisOnlyBackend.runOperation(analysisOnlyRequest,
            new OperationControl()).state == OperationState.completed);
        bool rejectedRootQuery;
        try
            analysisOnlyBackend.rootSummary();
        catch (CatalogBackendException failure)
            rejectedRootQuery = failure.code == CatalogBackendErrorCode.unsupportedFeature;
        assert(rejectedRootQuery);
        analysisOnlyBackend.close();

        auto backend = factory.open(target);
        assert(backend.target().mode == OperationStorageMode.jsonCatalog);
        assert(backend.sourceInfo().storageMode == OperationStorageMode.jsonCatalog);
        auto capabilities = backend.capabilities();
        assert(capabilities.supports(OperationKind.scan));
        assert(capabilities.supports(OperationKind.analyze));
        assert(!capabilities.supports(OperationKind.metadata));
        assert(capabilities.supportsConcurrentReads);
        assert(capabilities.supportsReadsDuringMutation);
        assert(capabilities.supportsFilteredExport);
        assert(capabilities.supportsArchiveEntryQueries);
        assert(capabilities.supportsTorrentEntryQueries);
        assert(capabilities.supportsFirstClassArchiveReferences);

        const auto root = backend.rootSummary();
        assert(root.childDirectoryCount == 2);
        assert(root.fileReferenceCount == 4);
        assert(root.aggregateSize == 50);

        CatalogDirectoryQuery directoryQuery;
        CatalogPageRequest oneDirectory;
        oneDirectory.limit = 1;
        auto firstDirectories = backend.listDirectories(directoryQuery, oneDirectory);
        assert(firstDirectories.directories.length == 1);
        assert(firstDirectories.directories[0].relativePath == "a");
        assert(firstDirectories.hasMore);
        CatalogPageRequest nextDirectoryRequest;
        nextDirectoryRequest.limit = 1;
        nextDirectoryRequest.cursor = firstDirectories.nextCursor;
        auto secondDirectories = backend.listDirectories(directoryQuery,
            nextDirectoryRequest);
        assert(secondDirectories.directories[0].relativePath == "b");

        CatalogFileQuery fileQuery;
        fileQuery.directoryId = firstDirectories.directories[0].id;
        CatalogPageRequest firstPageRequest;
        firstPageRequest.limit = 1;
        auto firstPage = backend.listFiles(fileQuery, firstPageRequest);
        assert(firstPage.files.length == 1);
        assert(firstPage.files[0].relativePath == "a/one.txt");
        assert(firstPage.files[0].contentId.isValid);
        assert(firstPage.hasMore);

        auto nextPage = backend.nextFilesPage(fileQuery, firstPage.nextCursor);
        assert(nextPage.files.length == 1);
        assert(nextPage.files[0].relativePath == "a/two-copy.txt");
        assert(nextPage.hasPrevious);
        assert(nextPage.hasMore);
        auto previousPage = backend.previousFilesPage(fileQuery,
            nextPage.previousCursor);
        assert(previousPage.files[0].relativePath == "a/one.txt");
        auto thirdPage = backend.nextFilesPage(fileQuery, nextPage.nextCursor);
        assert(thirdPage.files.length == 1);
        assert(thirdPage.files[0].relativePath == "a/three-copy.txt");
        assert(!thirdPage.hasMore);

        auto changedQuery = fileQuery;
        changedQuery.filter.pathText = "copy";
        bool rejectedMismatchedCursor;
        try
        {
            const auto unexpectedPage = backend.nextFilesPage(changedQuery,
                firstPage.nextCursor);
            rejectedMismatchedCursor = unexpectedPage.files.length == size_t.max;
        }
        catch (CatalogBackendException failure)
            rejectedMismatchedCursor = failure.code
                == CatalogBackendErrorCode.invalidCursor;
        assert(rejectedMismatchedCursor);

        auto otherBackend = factory.open(target);
        bool rejectedCrossSourceCursor;
        try
        {
            const auto unexpectedPage = otherBackend.nextFilesPage(fileQuery,
                firstPage.nextCursor);
            rejectedCrossSourceCursor = unexpectedPage.files.length == size_t.max;
        }
        catch (CatalogBackendException failure)
            rejectedCrossSourceCursor = failure.code
                == CatalogBackendErrorCode.invalidCursor;
        assert(rejectedCrossSourceCursor);
        otherBackend.close();

        /* UI handles are opaque kind-scoped keys; paths resolve back to IDs. */
        assert(backend.uiHandle(firstPage.files[0].referenceId)
            .startsWith("ref:"));
        assert(backend.uiHandle(firstPage.files[0].contentId)
            .startsWith("content:"));
        assert(backend.uiHandle(firstDirectories.directories[0].id)
            .startsWith("dir:"));
        assert(backend.uiHandle(firstPage.files[0].referenceId)
            != backend.uiHandle(firstPage.files[0].contentId));
        bool rejectedInvalidHandle;
        try
            backend.uiHandle(ReferenceId.init);
        catch (CatalogBackendException failure)
            rejectedInvalidHandle = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedInvalidHandle);

        /* Content rows collapse duplicate references into one display row. */
        auto contentPage = backend.listContents(CatalogContentQuery.init);
        assert(contentPage.total == 2);
        assert(contentPage.rows.length == 2);
        assert(contentPage.rows[0].displayPath == "a/one.txt");
        assert(contentPage.rows[0].referenceCount == 3);
        assert(contentPage.rows[1].displayPath == "b/photo.bmp");
        assert(contentPage.rows[1].referenceCount == 1);
        assert(contentPage.rows[1].hasImage);
        CatalogContentQuery contentTextQuery;
        contentTextQuery.filter.pathText = "photo";
        const auto filteredContents = backend.listContents(contentTextQuery);
        assert(filteredContents.rows.length == 1);
        assert(filteredContents.rows[0].displayPath == "b/photo.bmp");
        CatalogPageRequest contentRequest;
        contentRequest.limit = 1;
        const auto firstContents = backend.listContents(CatalogContentQuery.init,
            contentRequest);
        assert(firstContents.rows.length == 1 && firstContents.hasMore);
        const auto secondContents = backend.listContents(
            CatalogContentQuery.init,
            CatalogPageRequest(1, firstContents.nextCursor));
        assert(secondContents.rows.length == 1 && !secondContents.hasMore);

        /* Archive passwords are stored by reference path. */
        backend.setArchivePassword("a/one.txt", "secret");
        backend.setArchivePassword("a/one.txt", "");
        bool rejectedUnknownPasswordPath;
        try
            backend.setArchivePassword("missing.txt", "secret");
        catch (CatalogBackendException failure)
            rejectedUnknownPasswordPath = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedUnknownPasswordPath);

        assert(backend.resolveDirectory("a")
            == firstDirectories.directories[0].id);
        assert(!backend.resolveDirectory("").isValid);
        assert(!backend.resolveDirectory("a/missing").isValid);
        assert(backend.resolveReference("a/one.txt")
            == firstPage.files[0].referenceId);
        assert(!backend.resolveReference("a/missing.txt").isValid);
        assert(backend.loadReference(firstPage.files[0].referenceId).relativePath
            == "a/one.txt");
        bool rejectedMissingReference;
        try
            backend.loadReference(ReferenceId.init);
        catch (CatalogBackendException failure)
            rejectedMissingReference = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedMissingReference);

        const auto details = backend.loadContent(firstPage.files[0].contentId,
            CatalogDetailMask(true, false, false, false, false));
        assert(details.id == firstPage.files[0].contentId);
        assert(details.fingerprint.complete);
        CatalogFileQuery imageQuery;
        imageQuery.directoryId = secondDirectories.directories[0].id;
        auto imagePage = backend.listFiles(imageQuery);
        auto archivePage = backend.listArchiveEntries(imagePage.files[0].contentId);
        assert(archivePage.entries.length == 1);
        assert(archivePage.entries[0].name == "nested/readme.txt");
        auto archiveMembers = backend.listArchiveMembers(
            imagePage.files[0].referenceId);
        assert(archiveMembers.members.length == 1);
        assert(archiveMembers.members[0].contentId.isValid);
        assert(archiveMembers.members[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(archiveMembers.members[0].relativePath == "nested/readme.txt");
        bool rejectedNonContainer;
        try
            backend.listArchiveMembers(firstPage.files[0].referenceId);
        catch (CatalogBackendException failure)
            rejectedNonContainer = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedNonContainer);
        auto torrentPage = backend.listTorrentEntries(firstPage.files[0].contentId);
        assert(torrentPage.entries.length == 1);
        assert(torrentPage.entries[0].pathComponents == ["payload.bin"]);
        auto duplicateGroups = backend.queryDuplicateGroups();
        assert(duplicateGroups.length == 1);
        assert(duplicateGroups[0].fileSize == 10);
        auto exportOptions = CatalogExportOptions(CatalogExportFormat.jsonV5,
            "/tmp/subset.json");
        const auto subset = backend.exportSubset(CatalogSubsetQuery("a", CatalogFilter.init),
            exportOptions);
        assert(subset.referencesExported == 3);
        assert(subset.contentsExported == 1);
        assert(subset.committed);

        ScanOperationRequest scan;
        scan.operationId = 41;
        scan.target = target;
        const auto scanResult = backend.runOperation(scan, new OperationControl());
        assert(scanResult.state == OperationState.completed);
        assert(scanResult.scanSummary.filesAdded == 4);

        MetadataOperationRequest metadata;
        metadata.operationId = 42;
        metadata.target = target;
        bool rejectedAsUnsupported;
        try
            backend.runOperation(metadata, new OperationControl());
        catch (CatalogBackendException failure)
        {
            rejectedAsUnsupported = failure.code
                == CatalogBackendErrorCode.unsupportedOperation;
        }
        assert(rejectedAsUnsupported);

        AnalysisOperationRequest analyze;
        analyze.operationId = 44;
        analyze.target = target;
        const auto analyzeResult = backend.runOperation(analyze, new OperationControl());
        assert(analyzeResult.state == OperationState.completed);

        auto wrongTargetScan = scan;
        wrongTargetScan.operationId = 43;
        wrongTargetScan.target = OperationTarget.jsonTarget("library.json",
            "/different-root");
        bool rejectedMismatchedTarget;
        try
            backend.runOperation(wrongTargetScan, new OperationControl());
        catch (CatalogBackendException failure)
            rejectedMismatchedTarget = failure.code
                == CatalogBackendErrorCode.invalidTarget;
        assert(rejectedMismatchedTarget);

        backend.close();
        bool rejectedAfterClose;
        try
            backend.rootSummary();
        catch (CatalogBackendException failure)
            rejectedAfterClose = failure.code == CatalogBackendErrorCode.closed;
        assert(rejectedAfterClose);
    }
}
