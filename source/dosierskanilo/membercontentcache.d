/** Session-scoped, leased cache for extracted archive member bytes.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.membercontentcache;

import core.atomic : atomicLoad;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.time : dur;

import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, isFile, isSymlink, mkdirRecurse,
    rmdirRecurse;
import std.path : baseName, buildPath, dirName, extension;
import std.process : thisProcessID;
import std.string : empty, replace, startsWith, toLower;
import std.uuid : randomUUID;

import dosierarkivo.archive : normalizeArchiveEntryPath;
import dosierskanilo.catalogbackend : ArchiveEntryId, ContentId,
    ContentLocator, ReferenceId;
import dosierskanilo.operationlease : OperationTargetBusyException,
    TargetWriteLease;

/// Materialize one safely normalized member into the provided directory.
alias MemberContentMaterializer = bool delegate(string destinationDirectory);

/// Default byte limit for one member cache session.
enum ulong defaultMemberCacheByteLimit = 1_073_741_824;

/** Base class for member cache failures. */
class MemberContentCacheException : Exception
{
    /** Construct the exception with a human-readable message.
     *
     * Params:
     *     message = Description of the cache failure.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when an archive adapter cannot select the requested entry occurrence. */
class MemberContentNotExtractableException : MemberContentCacheException
{
    /** Construct the exception with a human-readable message.
     *
     * Params:
     *     message = Why the archive adapter could not select the entry.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when the cache session is already closed. */
class MemberContentCacheClosedException : MemberContentCacheException
{
    /** Construct the exception with a human-readable message.
     *
     * Params:
     *     message = Description of the attempted operation on a closed cache.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when the cache cannot honor its byte limit. */
class MemberContentCacheCapacityException : MemberContentCacheException
{
    /** Construct the exception with a human-readable message.
     *
     * Params:
     *     message = Description of the exceeded capacity limit.
     */
    this(string message)
    {
        super(message);
    }
}

/** Raised when extraction is cancelled through the shared flag. */
class MemberContentCancelledException : MemberContentCacheException
{
    /** Construct the exception with a human-readable message.
     *
     * Params:
     *     message = Description of the cancellation point that was hit.
     */
    this(string message)
    {
        super(message);
    }
}

/** One cache entry tracking one materialized archive member and its pins. */
private class CachedMember
{
    /// Session directory reserved for this entry; empty once it was disposed.
    string directory;
    /// Absolute path of the materialized member file.
    string filePath;
    /// Size of the materialized file in bytes; zero while unknown or disposed.
    ulong size;
    /// Number of outstanding leases that pin this entry.
    size_t leaseCount;
    /// Monotonic access tick used to choose the least recently used entry.
    size_t lastUse;
    /// True while a materialization for this key is still in flight.
    bool materializing;
}

/**
 * A pinned cache path. Call release when the extractor/preview no longer needs
 * it. A lease must not outlive the cache that created it; close the cache only
 * after releasing its leases.
 */
final class MemberContentLease
{
private:
    /// Cache that owns this lease and must outlive it.
    MemberContentCache owner;
    /// Cache key used to find the pinned entry when releasing.
    string key;
    /// Entry pinned by this lease, or null after release.
    CachedMember cachedEntry;
    /// Materialized path returned to the caller until release.
    string cachedPath;
    /// True once `release()` has run, guarding against double release.
    bool released;

    /** Construct a lease that pins one cache entry.
     *
     * Params:
     *     cache = Owning cache, which must outlive this lease.
     *     cacheKey = Key of the pinned entry inside the cache.
     *     entry = Cache entry whose file is borrowed.
     *     path = Materialized path exposed to the caller.
     */
    this(MemberContentCache cache, string cacheKey, CachedMember entry,
        string path)
    {
        owner = cache;
        key = cacheKey;
        cachedEntry = entry;
        cachedPath = path;
    }

public:
    /** Filesystem path to the pinned materialized file.
     *
     * Returns: The absolute path, valid until `release()` is called on this
     *     lease.
     */
    @property string path() const
    {
        return cachedPath;
    }

    /** Release this pin. Repeated calls are harmless. */
    void release()
    {
        synchronized (this)
        {
            if (released)
                return;
            released = true;
        }
        owner.release(key, cachedEntry);
        cachedEntry = null;
    }

    /** Release the pin if the caller did not release it explicitly. */
    ~this()
    {
        release();
    }
}

/**
 * Thread-safe single-flight archive member cache with bounded disk usage.
 *
 * Sessions are closed explicitly with close(). The cache deliberately has no
 * GC destructor because finalization order relative to outstanding leases is
 * not guaranteed; keep the cache alive until every lease is released.
 */
final class MemberContentCache
{
private:
    /// Guards all mutable cache state.
    Mutex mutex;
    /// Signals waiters when a materialization finishes or state changes.
    Condition changed;
    /// Bounds the number of concurrent materializations.
    Semaphore extractionSlots;
    /// Directory of this cache session.
    string sessionRoot;
    /// Exclusive lock that keeps stale-session cleanup from removing this session.
    TargetWriteLease sessionLease;
    /// Hard limit for the bytes retained by this session.
    ulong maximumBytes;
    /// Bytes currently retained in this session.
    ulong cachedBytes;
    /// Monotonic counter used to make session entry directories unique.
    size_t serial;
    /// Monotonic tick counter used for least-recently-used ordering.
    size_t accessClock;
    /// Entries keyed by the identity produced by `cacheKey`.
    CachedMember[string] membersByKey;
    /** Leases handed out whose holds were not yet released.
     *
     * Tracked separately from per-entry lease counts because a cached file
     * that vanished externally drops its entry (and with it the entry lease
     * count) while its lease is still outstanding; close() must still honor
     * those paths. */
    size_t outstandingLeases;
    /// True once `close()` has disposed the session.
    bool closed;

public:
    /** Create a cache session below `root`, or in a unique temporary session. */
    this(string root = "", ulong byteLimit = defaultMemberCacheByteLimit,
        size_t concurrentExtractions = 4)
    {
        enforce(byteLimit > 0, "Member cache byte limit must be positive.");
        enforce(concurrentExtractions > 0,
            "Member cache concurrency limit must be positive.");
        mutex = new Mutex();
        changed = new Condition(mutex);
        extractionSlots = new Semaphore(cast(uint) concurrentExtractions);
        if (root.length == 0)
        {
            import std.file : tempDir;
            root = buildPath(tempDir(), "dosierskanilo-member-cache");
        }
        mkdirRecurse(root);
        cleanupStaleSessions(root);
        sessionRoot = buildPath(root, "session-" ~ thisProcessID.to!string
            ~ "-" ~ randomUUID().toString());
        maximumBytes = byteLimit;
        /* Lease this session before it becomes visible to cleanupStaleSessions
         * of other processes: the flock makes concurrent cleaners skip it, and
         * racing stale-session cleanup cannot see an unleased directory. */
        sessionLease = TargetWriteLease.acquireRepositoryRoot(sessionRoot);
        cleanupStaleSessions(root);
        mkdirRecurse(sessionRoot);
    }

    /**
     * Acquire or materialize bytes for one archive-entry locator.
     *
     * The cache is single-flight per identity: concurrent callers share one
     * materialization. The returned lease pins the file until `release()`.
     *
     * Params:
     *   locator = structured container/entry location.
     *   contentId = known content identity, or an invalid ID when unknown.
     *   fallbackIdentity = stable cache key used before content identity exists.
     *   memberPath = normalized safe member path inside the cache directory.
     *   expectedSize = expected member size in bytes; zero when unknown.
     *   materialize = callback that writes the member below the supplied
     *     destination directory.
     *   cancellation = optional cooperative cancellation flag.
     * Returns:
     *   A lease the caller must release before closing the cache.
     * Throws:
     *   `MemberContentCacheException` for invalid paths or materialization
     *   failures, `MemberContentNotExtractableException` when the member cannot
     *   be materialized, `MemberContentCacheCapacityException` when the byte
     *   limit would be exceeded, `MemberContentCacheClosedException` after
     *   `close()`, and `MemberContentCancelledException` on cancellation.
     */
    MemberContentLease acquire(ContentLocator locator, ContentId contentId,
        string fallbackIdentity, string memberPath, ulong expectedSize,
        MemberContentMaterializer materialize, shared(bool)* cancellation = null)
    {
        bool safe;
        bool isDirectory;
        const auto normalizedPath = normalizeArchiveEntryPath(memberPath, safe,
            isDirectory);
        enforce(safe && !isDirectory && normalizedPath == memberPath,
            "Member cache paths must be normalized safe files.");
        enforce(materialize !is null, "Member cache requires a materializer.");
        if (cancellationRequested(cancellation))
            throw new MemberContentCancelledException(
                "Archive member extraction was cancelled.");
        if (expectedSize > maximumBytes)
            throw new MemberContentCacheCapacityException(
                "Archive member exceeds the configured cache limit.");

        const auto key = cacheKey(locator, contentId, fallbackIdentity,
            normalizedPath);
        CachedMember entry;
        while (true)
        {
            synchronized (mutex)
            {
                if (closed)
                    throw new MemberContentCacheClosedException(
                        "Member content cache is closed.");
                if (auto existing = key in membersByKey)
                {
                    entry = *existing;
                    if (entry.materializing)
                    {
                        if (cancellationRequested(cancellation))
                            throw new MemberContentCancelledException(
                                "Archive member extraction was cancelled.");
                        changed.wait(dur!"msecs"(100));
                        continue;
                    }
                    if (exists(entry.filePath) && isFile(entry.filePath))
                    {
                        ++entry.leaseCount;
                        ++outstandingLeases;
                        entry.lastUse = ++accessClock;
                        return new MemberContentLease(this, key, entry,
                            entry.filePath);
                    }
                    /* The file vanished externally. Its entry cannot serve
                     * requests, so it is disposed; a lease still holding the
                     * lost path is honored through the separate
                     * outstandingLeases counter, and the directory is kept
                     * while that lease lives. */
                    cachedBytes -= entry.size;
                    entry.filePath = "";
                    entry.size = 0;
                    if (entry.leaseCount == 0)
                        removeDirectory(entry.directory);
                    else
                        entry.directory = "";
                }

                entry = new CachedMember();
                entry.directory = buildPath(sessionRoot,
                    (++serial).to!string ~ "-" ~ randomUUID().toString());
                entry.filePath = buildPath(entry.directory, normalizedPath);
                entry.materializing = true;
                entry.lastUse = ++accessClock;
                membersByKey[key] = entry;
                break;
            }
        }

        bool acquiredSlot;
        try
        {
            while (!acquiredSlot)
            {
                if (cancellationRequested(cancellation))
                    throw new MemberContentCancelledException(
                        "Archive member extraction was cancelled.");
                acquiredSlot = extractionSlots.tryWait();
                if (!acquiredSlot)
                    acquiredSlot = extractionSlots.wait(dur!"msecs"(100));
            }
            mkdirRecurse(dirName(entry.filePath));
            auto extracted = materialize(entry.directory);
            if (cancellationRequested(cancellation))
                throw new MemberContentCancelledException(
                    "Archive member extraction was cancelled.");
            if (!extracted)
                throw new MemberContentNotExtractableException(
                    "Archive adapter could not select this member occurrence.");
            /* Archive extraction may preserve symbolic links. Never expose the
             * link target as member content, and never accept a path that
             * resolves outside the session directory. */
            if (isSymlink(entry.filePath))
                throw new MemberContentNotExtractableException(
                    "Archive member is a symbolic link; refusing to read its target.");
            if (!exists(entry.filePath) || !isFile(entry.filePath))
                throw new MemberContentNotExtractableException(
                    "Archive member materializer produced no file.");
            const auto actualSize = getSize(entry.filePath);
            if (actualSize > maximumBytes)
                throw new MemberContentCacheCapacityException(
                    "Extracted archive member exceeds the cache limit.");

            synchronized (mutex)
            {
                if (closed)
                    throw new MemberContentCacheClosedException(
                        "Member content cache closed during extraction.");
                while (cachedBytes + actualSize > maximumBytes)
                    if (!evictLeastRecentlyUsed(key))
                        throw new MemberContentCacheCapacityException(
                            "Member cache is full of pinned files.");
                entry.size = actualSize;
                entry.leaseCount = 1;
                entry.lastUse = ++accessClock;
                entry.materializing = false;
                cachedBytes += actualSize;
                changed.notifyAll();
            }
            ++outstandingLeases;
            return new MemberContentLease(this, key, entry, entry.filePath);
        }
        catch (Throwable failure)
        {
            synchronized (mutex)
            {
                if (key in membersByKey && membersByKey[key] is entry)
                    membersByKey.remove(key);
                entry.materializing = false;
                changed.notifyAll();
            }
            removeDirectory(entry.directory);
            throw failure;
        }
        finally
        {
            if (acquiredSlot)
                extractionSlots.notify();
        }
    }

    /** Current cache session directory.
     *
     * It is session scratch space, never a FileSpec path.
     *
     * Returns: The absolute session root path.
     */
    @property string rootPath() const
    {
        return sessionRoot;
    }

    /** Bytes currently retained in the cache.
     *
     * Returns: The sum of the sizes of materialized, non-disposed entries.
     */
    @property ulong bytesUsed()
    {
        synchronized (mutex)
            return cachedBytes;
    }

    /** Remove this session's unpinned contents and close the service. */
    void close()
    {
        synchronized (mutex)
        {
            if (closed)
                return;
            foreach (entry; membersByKey.values)
                enforce(!entry.materializing && entry.leaseCount == 0,
                    "Cannot close a member cache while paths are leased.");
            enforce(outstandingLeases == 0,
                "Cannot close a member cache while paths are leased.");
            closed = true;
            membersByKey = null;
            cachedBytes = 0;
            changed.notifyAll();
        }
        removeDirectory(sessionRoot);
        if (sessionLease !is null)
            sessionLease.release();
    }

private:
    /** Release one pin and adjust the cache accounting.
     *
     * Params:
     *     key = Cache key under which the entry was stored; informational, as
     *         the entry object itself is matched by identity.
     *     entry = Entry to unpin, or `null` when only the outstanding-lease
     *         counter needs adjusting.
     */
    void release(string key, CachedMember entry)
    {
        synchronized (mutex)
        {
            if (outstandingLeases > 0)
                --outstandingLeases;
            if (entry !is null)
                foreach (cached; membersByKey.values)
                    if (cached is entry)
                    {
                        if (cached.leaseCount > 0)
                            --cached.leaseCount;
                        cached.lastUse = ++accessClock;
                        changed.notifyAll();
                    }
        }
    }

    /** Remove the oldest unpinned entry other than `exceptKey`.
     *
     * Params:
     *     exceptKey = Key of the entry currently being materialized and
     *         therefore not eligible for eviction.
     * Returns: `true` when an unpinned entry was removed; `false` when no
     *     entry could be evicted.
     */
    bool evictLeastRecentlyUsed(string exceptKey)
    {
        string victimKey;
        size_t oldest = size_t.max;
        foreach (key, entry; membersByKey)
            if (key != exceptKey && !entry.materializing
                && entry.leaseCount == 0 && entry.lastUse < oldest)
            {
                victimKey = key;
                oldest = entry.lastUse;
            }
        if (victimKey.length == 0)
            return false;
        auto victim = membersByKey[victimKey];
        cachedBytes -= victim.size;
        membersByKey.remove(victimKey);
        removeDirectory(victim.directory);
        return true;
    }

    /** Build the stable single-flight identity for one member request.
     *
     * The key prefers the content identity, then the archive locator, and only
     * falls back to `fallbackIdentity` for other locator kinds. The member path
     * and its lower-cased extension are appended so the same content in
     * different file types occupies separate entries.
     *
     * Params:
     *     locator = Structured container/entry location to identify.
     *     contentId = Known content identity, or an invalid ID when unknown.
     *     fallbackIdentity = Stable identity used when no other identity exists.
     *     memberPath = Normalized safe member path used as part of the key.
     * Returns: A key suitable for `membersByKey`; at least a valid identity
     *     prefix followed by the member path.
     * Throws: `Exception` when neither a valid content identity nor a usable
     *     archive locator/fallback identity is supplied.
     */
    string cacheKey(ContentLocator locator, ContentId contentId,
        string fallbackIdentity, string memberPath) const
    {
        string identity;
        if (contentId.isValid)
            identity = "content:" ~ contentId.adapterToken;
        else if (locator.kind == ContentLocator.Kind.archiveEntry)
            identity = "entry:" ~ locator.archiveEntry.containerReferenceId.adapterToken
                ~ ":" ~ locator.archiveEntry.entryId.adapterToken;
        else
            identity = "locator:" ~ fallbackIdentity;
        enforce(identity.length > "locator:".length,
            "Member cache requires a content identity or archive locator.");
        return identity ~ "\0" ~ memberPath ~ "\0"
            ~ extension(memberPath).toLower;
    }

    /** Read a shared cancellation flag atomically.
     *
     * Params:
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: `true` when the flag is non-null and set; `false` otherwise.
     */
    bool cancellationRequested(shared(bool)* cancellation) const
    {
        if (cancellation is null)
            return false;
        return atomicLoad(*cancellation);
    }

    /** Recursively remove an entry directory, ignoring removal failures.
     *
     * Missing paths are treated as success, and filesystem errors are swallowed
     * so cleanup cannot mask the operation that triggered it.
     *
     * Params:
     *     path = Directory to remove; an empty path is ignored.
     */
    void removeDirectory(string path)
    {
        try
            if (path.length > 0 && exists(path))
                rmdirRecurse(path);
        catch (Exception)
        {
        }
    }

    /** Remove session directories left behind by exited processes.
     *
     * A session directory is removed unless another process still holds its
     * write lease. Entries that cannot be inspected or locked are left alone.
     *
     * Params:
     *     root = Cache parent directory scanned one level deep.
     */
    void cleanupStaleSessions(string root)
    {
        import std.file : DirEntry, SpanMode, dirEntries, isDir;

        foreach (DirEntry entry; dirEntries(root, SpanMode.shallow))
        {
            if (!isDir(entry.name) || !entry.name.baseName.startsWith("session-"))
                continue;
            TargetWriteLease staleLease;
            try
                staleLease = TargetWriteLease.acquireRepositoryRoot(entry.name);
            catch (OperationTargetBusyException)
                continue;
            catch (Exception)
                continue;
            scope (exit)
                staleLease.release();
            removeDirectory(entry.name);
        }
    }
}

/// Guards access to the process-wide cache pointer.
private __gshared Object sharedCacheGuard;
/// Process-wide cache instance, or `null` when none is configured.
private __gshared MemberContentCache processMemberContentCache;

/** Create the guard object during module initialization. */
shared static this()
{
    sharedCacheGuard = new Object();
}

/** Close and forget the process-wide cache during module shutdown. */
shared static ~this()
{
    synchronized (sharedCacheGuard)
        if (processMemberContentCache !is null)
        {
            try
                processMemberContentCache.close();
            catch (Exception)
            {
            }
            processMemberContentCache = null;
        }
}

/** Process-wide cache shared by repository and JSON operation workers.
 *
 * Returns: The existing shared cache, or a newly created default-configured
 *     cache when none exists yet.
 */
MemberContentCache sharedMemberContentCache()
{
    synchronized (sharedCacheGuard)
    {
        if (processMemberContentCache is null)
            processMemberContentCache = new MemberContentCache();
        return processMemberContentCache;
    }
}

/**
 * Replace the process-wide cache with an explicitly configured session.
 *
 * Must be called before any worker thread uses sharedMemberContentCache():
 * the swap only serializes configuration changes, and closing the old cache
 * while another thread still holds leases would fail (or, once a close is
 * refused, leave the configured root unused).
 *
 * Params:
 *     root = Parent directory for the new session; an empty string selects the
 *         system temporary directory.
 *     byteLimit = Maximum number of bytes the session may retain.
 */
void configureSharedMemberContentCache(string root, ulong byteLimit)
{
    synchronized (sharedCacheGuard)
    {
        if (processMemberContentCache !is null)
        {
            processMemberContentCache.close();
            processMemberContentCache = null;
        }
        processMemberContentCache = new MemberContentCache(root, byteLimit);
    }
}

/**
 * Close and remove the process-wide cache session.
 *
 * Frontends call this after stopping preview and worker threads so the session
 * directory disappears before the process exits.
 *
 * Returns: `true` when the session was closed or none existed; `false` when
 *     leased paths or an in-flight extraction still block the close. A refused
 *     close keeps the session for the process-exit destructor.
 */
bool closeSharedMemberContentCache()
{
    synchronized (sharedCacheGuard)
    {
        if (processMemberContentCache is null)
            return true;
        try
            processMemberContentCache.close();
        catch (Exception)
            return false;
        processMemberContentCache = null;
        return true;
    }
}

@("shared member cache closes explicitly and refuses while a member is leased")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "member-cache-shared-close-"
        ~ randomUUID().toString());
    scope (exit)
    {
        closeSharedMemberContentCache();
        if (exists(root))
            rmdirRecurse(root);
    }
    configureSharedMemberContentCache(root, 1024);
    auto cache = sharedMemberContentCache();
    const auto locator = ContentLocator.entry(ReferenceId("shared-close-root"),
        ArchiveEntryId("shared-close-entry"));
    auto lease = cache.acquire(locator, ContentId.init, "shared-close",
        "member.bin", 4, (string destinationDirectory) {
            const auto outputPath = buildPath(destinationDirectory,
                "member.bin");
            mkdirRecurse(dirName(outputPath));
            write(outputPath, "data");
            return true;
        });
    assert(!closeSharedMemberContentCache(),
        "A leased member must refuse an explicit cache close.");
    lease.release();
    assert(closeSharedMemberContentCache(),
        "The cache closes once its leases are released.");
    assert(closeSharedMemberContentCache(),
        "Closing an already closed shared cache is harmless.");
}

@("member cache coalesces extraction and keeps leased files")
unittest
{
    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import std.datetime : dur;
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const auto parent = buildPath(tempDir(), "member-cache-single-flight-"
        ~ randomUUID().toString());
    auto cache = new MemberContentCache(parent, 1024, 2);
    const auto cacheRoot = cache.rootPath;
    scope (exit)
    {
        cache.close();
        if (exists(parent))
            rmdirRecurse(parent);
    }

    const auto locator = ContentLocator.entry(ReferenceId("cache-root"),
        ArchiveEntryId("entry-0"));
    auto callsMutex = new Mutex();
    size_t materializerCalls;
    MemberContentLease[] leases = new MemberContentLease[2];
    auto materialize = (string destinationDirectory) {
        synchronized (callsMutex)
            ++materializerCalls;
        Thread.sleep(dur!"msecs"(40));
        const auto outputPath = buildPath(destinationDirectory, "nested", "member.bin");
        mkdirRecurse(dirName(outputPath));
        write(outputPath, "cached");
        return true;
    };

    auto first = new Thread({
        leases[0] = cache.acquire(locator, ContentId.init,
            "container!/nested/member.bin!~0", "nested/member.bin", 6,
            materialize);
    });
    auto second = new Thread({
        leases[1] = cache.acquire(locator, ContentId.init,
            "container!/nested/member.bin!~0", "nested/member.bin", 6,
            materialize);
    });
    first.start();
    second.start();
    first.join();
    second.join();

    assert(materializerCalls == 1);
    assert(leases[0].path == leases[1].path);
    assert(getSize(leases[0].path) == 6);
    assert(cache.bytesUsed == 6);
    leases[0].release();
    assert(exists(leases[1].path));
    leases[1].release();
    cache.close();
    assert(!exists(cacheRoot));
}

@("member cache evicts only unpinned files and enforces its byte limit")
unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const auto parent = buildPath(tempDir(), "member-cache-eviction-"
        ~ randomUUID().toString());
    auto cache = new MemberContentCache(parent, 4, 1);
    scope (exit)
    {
        cache.close();
        if (exists(parent))
            rmdirRecurse(parent);
    }

    bool delegate(string) firstMaterializer = (string destinationDirectory) {
        const auto outputPath = buildPath(destinationDirectory, "first.bin");
        mkdirRecurse(dirName(outputPath));
        write(outputPath, "1234");
        return true;
    };
    bool delegate(string) secondMaterializer = (string destinationDirectory) {
        const auto outputPath = buildPath(destinationDirectory, "second.bin");
        mkdirRecurse(dirName(outputPath));
        write(outputPath, "5678");
        return true;
    };
    const auto firstLocator = ContentLocator.entry(ReferenceId("cache-root"),
        ArchiveEntryId("entry-first"));
    const auto secondLocator = ContentLocator.entry(ReferenceId("cache-root"),
        ArchiveEntryId("entry-second"));
    auto first = cache.acquire(firstLocator, ContentId.init, "first", "first.bin",
        4, firstMaterializer);
    const auto firstPath = first.path;
    assertThrown!Exception(cache.acquire(secondLocator, ContentId.init,
        "second", "second.bin", 4, secondMaterializer));
    assert(exists(firstPath));
    first.release();
    auto second = cache.acquire(secondLocator, ContentId.init, "second",
        "second.bin", 4, secondMaterializer);
    assert(!exists(firstPath));
    assert(exists(second.path));
    second.release();
}

@("member cache removes stale sessions but keeps leased sessions")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto parent = buildPath(tempDir(), "member-cache-session-cleanup-"
        ~ randomUUID().toString());
    const auto staleSession = buildPath(parent, "session-999999999-stale");
    mkdirRecurse(staleSession);
    write(buildPath(staleSession, "stale.bin"), "stale");
    scope (exit)
        if (exists(parent))
            rmdirRecurse(parent);

    auto first = new MemberContentCache(parent);
    assert(!exists(staleSession));
    const auto firstSession = first.rootPath;
    auto second = new MemberContentCache(parent);
    assert(exists(firstSession));
    second.close();
    first.close();
    assert(!exists(firstSession));
}

@("member cache keeps lease accounting for stale entries and close honours it")
unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const auto parent = buildPath(tempDir(), "member-cache-stale-lease-"
        ~ randomUUID().toString());
    auto cache = new MemberContentCache(parent, 1024, 1);
    scope (exit)
    {
        if (exists(parent))
            rmdirRecurse(parent);
    }

    const auto locator = ContentLocator.entry(ReferenceId("cache-root"),
        ArchiveEntryId("entry-0"));
    bool delegate(string) materialize = (string destinationDirectory) {
        const auto outputPath = buildPath(destinationDirectory, "stale.bin");
        mkdirRecurse(dirName(outputPath));
        write(outputPath, "payload");
        return true;
    };

    auto first = cache.acquire(locator, ContentId.init,
        "container!/stale.bin!~0", "stale.bin", 7, materialize);
    const auto firstPath = first.path;

    /* Externally delete the cached file while the lease is outstanding. */
    rmdirRecurse(dirName(firstPath));
    assert(!exists(firstPath));

    /* A new acquire materializes a fresh entry while the stale lease lives. */
    auto second = cache.acquire(locator, ContentId.init,
        "container!/stale.bin!~0", "stale.bin", 7, materialize);
    assert(second.path != firstPath);
    assert(exists(second.path));

    /* close() must refuse while the stale lease is outstanding, and must not
     * destroy the session tree the outstanding lease paths live in. */
    assertThrown!Exception(cache.close());
    assert(exists(second.path));

    first.release();
    assertThrown!Exception(cache.close());
    assert(exists(second.path));
    second.release();
    cache.close();
    assert(!exists(cache.rootPath));
}

@("member cache cancellation discards a materialized member")
unittest
{
    import core.atomic : atomicStore;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath, dirName;
    import std.uuid : randomUUID;

    const parent = buildPath(tempDir(), "member-cache-cancel-"
        ~ randomUUID().toString());
    auto cache = new MemberContentCache(parent, 1024, 1);
    scope (exit)
    {
        cache.close();
        if (exists(parent))
            rmdirRecurse(parent);
    }

    shared bool cancelled;
    const auto locator = ContentLocator.entry(ReferenceId("cache-cancel"),
        ArchiveEntryId("entry-0"));
    auto materialize = (string destinationDirectory) {
        const outputPath = buildPath(destinationDirectory, "member.bin");
        mkdirRecurse(dirName(outputPath));
        write(outputPath, "cancelled");
        atomicStore(cancelled, true);
        return true;
    };

    bool rejected;
    try
        cache.acquire(locator, ContentId.init, "container!/member.bin!~0",
            "member.bin", 9, materialize, &cancelled);
    catch (MemberContentCancelledException)
        rejected = true;
    assert(rejected);
    assert(cache.bytesUsed == 0);
}
