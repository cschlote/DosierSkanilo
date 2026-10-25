/** Session-scoped, leased cache for extracted archive member bytes. */
module dosierskanilo.membercontentcache;

import core.atomic : atomicLoad;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.sync.semaphore : Semaphore;
import core.time : dur;

import std.conv : to;
import std.exception : enforce;
import std.file : exists, getSize, isFile, mkdirRecurse, rmdirRecurse;
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

/** Base class for member cache failures. */
class MemberContentCacheException : Exception
{
    this(string message)
    {
        super(message);
    }
}

/** Raised when an archive adapter cannot select the requested entry occurrence. */
class MemberContentNotExtractableException : MemberContentCacheException
{
    this(string message)
    {
        super(message);
    }
}

/** Raised when the cache session is already closed. */
class MemberContentCacheClosedException : MemberContentCacheException
{
    this(string message)
    {
        super(message);
    }
}

/** Raised when the cache cannot honor its byte limit. */
class MemberContentCacheCapacityException : MemberContentCacheException
{
    this(string message)
    {
        super(message);
    }
}

/** Raised when extraction is cancelled through the shared flag. */
class MemberContentCancelledException : MemberContentCacheException
{
    this(string message)
    {
        super(message);
    }
}

private class CachedMember
{
    string directory;
    string filePath;
    ulong size;
    size_t leaseCount;
    size_t lastUse;
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
    MemberContentCache owner;
    string key;
    string cachedPath;
    bool released;

    this(MemberContentCache cache, string cacheKey, string path)
    {
        owner = cache;
        key = cacheKey;
        cachedPath = path;
    }

public:
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
        owner.release(key);
    }

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
    Mutex mutex;
    Condition changed;
    Semaphore extractionSlots;
    string sessionRoot;
    TargetWriteLease sessionLease;
    ulong maximumBytes;
    ulong cachedBytes;
    size_t serial;
    size_t accessClock;
    CachedMember[string] membersByKey;
    bool closed;

public:
    /** Create a cache session below `root`, or in a unique temporary session. */
    this(string root = "", ulong byteLimit = 1_073_741_824,
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
        mkdirRecurse(sessionRoot);
        sessionLease = TargetWriteLease.acquireRepositoryRoot(sessionRoot);
    }

    /** Acquire or materialize bytes for one archive-entry locator. */
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
                        entry.lastUse = ++accessClock;
                        return new MemberContentLease(this, key, entry.filePath);
                    }
                    cachedBytes -= entry.size;
                    membersByKey.remove(key);
                    if (entry.leaseCount == 0)
                        removeDirectory(entry.directory);
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
            return new MemberContentLease(this, key, entry.filePath);
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

    /** Current cache directory. It is session scratch, never a FileSpec path. */
    @property string rootPath() const
    {
        return sessionRoot;
    }

    /** Bytes currently retained in the cache. */
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
    void release(string key)
    {
        synchronized (mutex)
        {
            if (auto entry = key in membersByKey)
            {
                if ((*entry).leaseCount > 0)
                    --(*entry).leaseCount;
                (*entry).lastUse = ++accessClock;
                changed.notifyAll();
            }
        }
    }

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

    bool cancellationRequested(shared(bool)* cancellation) const
    {
        if (cancellation is null)
            return false;
        return atomicLoad(*cancellation);
    }

    void removeDirectory(string path)
    {
        try
            if (path.length > 0 && exists(path))
                rmdirRecurse(path);
        catch (Exception)
        {
        }
    }

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

private __gshared Object sharedCacheGuard;
private __gshared MemberContentCache processMemberContentCache;

shared static this()
{
    sharedCacheGuard = new Object();
}

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

/** Process-wide cache shared by repository and JSON operation workers. */
MemberContentCache sharedMemberContentCache()
{
    synchronized (sharedCacheGuard)
    {
        if (processMemberContentCache is null)
            processMemberContentCache = new MemberContentCache();
        return processMemberContentCache;
    }
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
