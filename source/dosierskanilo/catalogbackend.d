/** Storage-neutral catalog query and operation contract. */
module dosierskanilo.catalogbackend;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.string : split, startsWith;

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
    private string token;

    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ContentId token cannot be empty.");
        this.token = token;
    }

    package(dosierskanilo) @property string adapterToken() const { return token; }

    /// Whether an adapter-issued identifier has been assigned.
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /// Compare identifiers within their catalog-source scope.
    bool opEquals(const ContentId other) const
    {
        return token == other.token;
    }

    /// Stable hash within this identifier's source scope.
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /// Redacted display value that does not expose the opaque token.
    string toString() const
    {
        return isValid ? "ContentId(<opaque>)" : "ContentId(<invalid>)";
    }
}

/** Opaque identity of one reference/location in one catalog source. */
struct ReferenceId
{
    private string token;

    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ReferenceId token cannot be empty.");
        this.token = token;
    }

    package(dosierskanilo) @property string adapterToken() const { return token; }

    /// Whether an adapter-issued identifier has been assigned.
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /// Compare identifiers within their catalog-source scope.
    bool opEquals(const ReferenceId other) const
    {
        return token == other.token;
    }

    /// Stable hash within this identifier's source scope.
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /// Redacted display value that does not expose the opaque token.
    string toString() const
    {
        return isValid ? "ReferenceId(<opaque>)" : "ReferenceId(<invalid>)";
    }
}

/** Opaque identity of a directory projection in one catalog source. */
struct DirectoryId
{
    private string token;

    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "DirectoryId token cannot be empty.");
        this.token = token;
    }

    package(dosierskanilo) @property string adapterToken() const { return token; }

    /// Whether an adapter-issued identifier has been assigned.
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /// Compare identifiers within their catalog-source scope.
    bool opEquals(const DirectoryId other) const
    {
        return token == other.token;
    }

    /// Stable hash within this identifier's source scope.
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /// Redacted display value that does not expose the opaque token.
    string toString() const
    {
        return isValid ? "DirectoryId(<opaque>)" : "DirectoryId(<invalid>)";
    }
}

/** Opaque entry identity scoped to a container content/index version. */
struct ArchiveEntryId
{
    private string token;

    package(dosierskanilo) this(string token)
    {
        enforce(token.length > 0, "ArchiveEntryId token cannot be empty.");
        this.token = token;
    }

    package(dosierskanilo) @property string adapterToken() const { return token; }

    /// Whether an adapter-issued identifier has been assigned.
    @property bool isValid() const
    {
        return token.length > 0;
    }

    /// Compare identifiers within their container-index scope.
    bool opEquals(const ArchiveEntryId other) const
    {
        return token == other.token;
    }

    /// Stable hash within this identifier's container-index scope.
    size_t toHash() const nothrow @safe
    {
        return token.hashOf;
    }

    /// Redacted display value that does not expose the opaque token.
    string toString() const
    {
        return isValid ? "ArchiveEntryId(<opaque>)" : "ArchiveEntryId(<invalid>)";
    }
}

/** Opaque position in one source/query/sort result sequence. */
struct CatalogPageCursor
{
    private size_t index;
    private size_t pageSize;
    private string queryToken;
    private bool valid;

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

    package(dosierskanilo) @property size_t adapterIndex() const { return index; }
    package(dosierskanilo) @property size_t adapterPageSize() const { return pageSize; }
    package(dosierskanilo) @property string adapterQueryToken() const { return queryToken; }

    /// Whether this is a continuation cursor rather than the first-page marker.
    @property bool isValid() const
    {
        return valid;
    }

    /// Compare opaque continuation values.
    bool opEquals(const CatalogPageCursor other) const
    {
        return index == other.index && pageSize == other.pageSize
            && queryToken == other.queryToken && valid == other.valid;
    }

    /// Stable hash without revealing the query/source-bound cursor token.
    size_t toHash() const nothrow @safe
    {
        return queryToken.hashOf ^ index ^ pageSize;
    }

    /// Redacted display value that does not expose source/query state.
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

    /// Construct a validated source-root-relative filesystem locator.
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

    /// Construct a validated archive-entry locator chain element.
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
    notChecked,
    available,
    unavailable
}

/** Lifecycle of one independently extracted metadata family. */
enum CatalogExtractorState
{
    notRequested,
    pending,
    completed,
    empty,
    failed
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
    image,
    video,
    audio,
    text
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
    pathAscending,
    pathDescending,
    sizeAscending,
    sizeDescending
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

/** Select optional detail families loaded with a content snapshot. */
struct CatalogDetailMask
{
    bool fingerprint; /// Include content digest details.
    bool fileType; /// Include the full file-type signature.
    bool media; /// Include typed media streams.
    bool archiveSummary; /// Include archive index state/summary.
    bool torrentSummary; /// Include torrent manifest summary.
}

/** Current archive metadata view. First-class content references arrive in WP-13.5. */
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

    /// Whether this backend accepts the specified operation kind.
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
    invalidTarget,
    invalidIdentifier,
    invalidLocator,
    invalidCursor,
    unsupportedOperation,
    unsupportedFeature,
    closed,
    backendFailure
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

/** One source-bound, storage-neutral view over JSON or repository storage.
 *
 * Query results are detached value snapshots. Cursors are opaque, source- and
 * query-bound values; a committed mutation may invalidate them. `close()` is
 * called after any operation and its workers have completed.
 */
interface CatalogBackend
{
    /** The explicit target accepted by the factory that opened this backend. */
    OperationTarget target();

    /** Storage-neutral source label and kind. */
    CatalogSourceInfo sourceInfo();

    /** Repository-style metadata for CLI info output. */
    RepositoryInfo repositoryInfo();

    /** Supported operations/features; unsupported behavior is never inferred. */
    CatalogBackendCapabilities capabilities();

    /** Return bounded aggregates for the source root under the shared filter. */
    CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init);

    /** List immediate child directories under the requested parent. */
    CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List matching immediate file references in the selected stable order. */
    CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Continue forward using a cursor issued for this source and query. */
    CatalogFilePage nextFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /** Continue backward and return rows in the query's display order. */
    CatalogFilePage previousFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /** Load one detached content snapshot, including only requested details. */
    CatalogContentSnapshot loadContent(ContentId contentId,
        CatalogDetailMask details = CatalogDetailMask.init);

    /** Page through the current archive index for one content record. */
    CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List bounded, structured member references for one selected container reference. */
    CatalogArchiveMemberPage listArchiveMembers(ReferenceId containerReferenceId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Page through torrent manifest descriptors for one content record. */
    CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Page through repository-style blob query results. */
    RepositoryBlobPage queryBlobs(RepositoryQueryOptions options);

    /** Return duplicate groups without mutating the source. */
    RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100);

    /** Export a selected relationship-closed subset to an explicit destination. */
    CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options);

    /**
     * Export a subset with cooperative cancellation. Implementations stop at
     * safe checkpoints and leave `committed` false when cancelled.
     */
    CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
        CatalogExportOptions options, OperationControl control,
        ulong operationId);

    /** Import a JSON catalog into the bound repository source. */
    void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init);

    /**
     * Import a JSON catalog with cooperative cancellation. Returns `false` when
     * the import was cancelled before commit.
     */
    bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId);

    /** Run scan synchronously and require its explicit root to match this source. */
    OperationResult runOperation(ScanOperationRequest request,
        OperationControl control);

    /** Run metadata synchronously when supported and bound to this source. */
    OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control);

    /**
     * Run analysis synchronously when supported. JSON analysis may omit its
     * filesystem root; a supplied root must match the opened source.
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
     * Open exactly this target or throw a typed target/open error. JSON targets
     * may omit the filesystem root when they are used only for analysis.
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

    private class FakeCatalogBackend : CatalogBackend
    {
        private OperationTarget sourceTarget;
        private string instanceToken;
        private bool closed;
        private ContentId contentOne;
        private ContentId contentTwo;
        private DirectoryId directoryA;
        private DirectoryId directoryB;
        private CatalogFile[] files;
        private CatalogDirectory[] directories;

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

        private void requireOpen() const
        {
            if (closed)
                throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                    "Catalog backend is closed.");
        }

        private void requireTreeQueries() const
        {
            requireOpen();
            if (sourceTarget.mode == OperationStorageMode.jsonCatalog
                && sourceTarget.filesystemRoot.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "JSON tree queries require an explicit filesystem root.");
        }

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

        private bool matches(CatalogFile file, CatalogFilter filter) const
        {
            auto path = file.relativePath;
            auto text = filter.pathText;
            if (text.length > 0)
            {
                if (!filter.caseSensitive)
                {
                    path = path.toLower;
                    text = text.toLower;
                }
                if (!path.canFind(text))
                    return false;
            }
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

        private string sourceToken() const
        {
            return instanceToken ~ "\0" ~ (cast(int) sourceTarget.mode).to!string ~ "\0"
                ~ sourceTarget.repositoryRoot ~ "\0" ~ sourceTarget.catalogPath
                ~ "\0" ~ sourceTarget.filesystemRoot;
        }

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

        private string fileQueryToken(CatalogFileQuery query) const
        {
            return sourceToken() ~ "\0file\0" ~ query.directoryId.token ~ "\0"
                ~ filterToken(query.filter) ~ "\0"
                ~ (cast(int) query.sortOrder).to!string;
        }

        private string directoryQueryToken(CatalogDirectoryQuery query) const
        {
            return sourceToken() ~ "\0directory\0" ~ query.parentId.token
                ~ "\0" ~ filterToken(query.filter);
        }

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

        override OperationTarget target()
        {
            requireOpen();
            return sourceTarget;
        }

        override CatalogSourceInfo sourceInfo()
        {
            requireOpen();
            CatalogSourceInfo result;
            result.storageMode = sourceTarget.mode;
            result.displayName = sourceTarget.mode == OperationStorageMode.jsonCatalog
                ? sourceTarget.catalogPath : "in-memory repository";
            return result;
        }

        override RepositoryInfo repositoryInfo()
        {
            requireOpen();
            RepositoryInfo result;
            result.rootPath = sourceTarget.mode == OperationStorageMode.repository
                ? sourceTarget.repositoryRoot : sourceTarget.catalogPath;
            result.schemaVersion = sourceTarget.mode == OperationStorageMode.repository ? 4 : 5;
            return result;
        }

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
            return result;
        }

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

        override CatalogFilePage listFiles(CatalogFileQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            return filePage(query, page);
        }

        override CatalogFilePage nextFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

        override CatalogFilePage previousFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

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

        override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
        {
            enforce(limit > 0);
            return [RepositoryDuplicateGroup(10, [1])];
        }

        override CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
            CatalogExportOptions options, OperationControl control,
            ulong operationId)
        {
            return exportSubset(query, options);
        }

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

        override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
        {
            requireOpen();
            assert(jsonPath.length > 0);
            cast(void) options;
        }

        override bool importJsonControlled(string jsonPath,
            JsonImportOptions options, OperationControl control,
            ulong operationId)
        {
            importJson(jsonPath, options);
            return true;
        }

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

        override void close()
        {
            closed = true;
        }

        private void requireSupported(OperationKind operation)
        {
            if (!capabilities().supports(operation))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedOperation,
                    "The opened source does not support this operation.");
        }
    }

    private class FakeCatalogBackendFactory : CatalogBackendFactory
    {
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
