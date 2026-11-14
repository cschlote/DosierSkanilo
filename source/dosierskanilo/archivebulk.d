/** Bulk archive extraction for deep scans.
 *
 * Deep scans normally extract one member at a time through the member cache.
 * That is the right model for previews and one-off access, but it starts one
 * archive process per member and repeatedly decompresses sequential streams.
 * This module provides a separate staging layer for the scanner: one archive
 * is extracted once into a bounded temporary tree, and members are hashed
 * directly from that tree.
 *
 * The member cache remains the fallback and the only path used for previews.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.archivebulk;

import core.sync.mutex : Mutex;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, mkdirRecurse,
    rmdirRecurse, tempDir;
import std.path : baseName, buildPath;
import std.process : thisProcessID;
import std.uuid : randomUUID;

import dosierskanilo.archivebulkpolicy;
public import dosierskanilo.archivebulkpolicy;
import dosierskanilo.diskspace : availableBytes;
import dosierskanilo.operationlease : OperationTargetBusyException,
    TargetWriteLease;

/** Return the default staging limit for a directory.
 *
 * The limit uses half of the currently available space, capped at
 * `maximumArchiveStagingByteLimit`, so a large `/tmp` is used without letting
 * one scan consume the whole filesystem.
 *
 * Params:
 *     root = Existing staging root or its parent.
 * Returns: The derived byte limit, or the fallback when space is unknown.
 */
ulong defaultArchiveStagingByteLimitFor(string root) @safe
{
    const free = availableBytes(root);
    if (free == 0)
        return fallbackArchiveStagingByteLimit;
    auto limit = free / 2;
    if (limit > maximumArchiveStagingByteLimit)
        limit = maximumArchiveStagingByteLimit;
    if (limit == 0)
        limit = fallbackArchiveStagingByteLimit;
    return limit;
}

/** Serve one archive-owned reservation in the shared staging session. */
final class ArchiveBulkReservation
{
private:
    ArchiveBulkStaging owner;
    string directory;
    ulong bytes;
    bool released;

public:
    /// Construct a reservation; callers receive these from `reserve()`.
    this(ArchiveBulkStaging owner, string directory, ulong bytes)
    {
        this.owner = owner;
        this.directory = directory;
        this.bytes = bytes;
    }

    /// Return the staging directory that receives the extracted archive.
    @property string path() const @safe
    {
        return directory;
    }

    /// Reserve bytes held by this reservation.
    @property ulong reservedBytes() const @safe
    {
        return bytes;
    }

    /** Release the reservation and remove its staging tree.
     *
     * Safe to call more than once; the owner accounts for it only once.
     */
    void release()
    {
        if (released)
            return;
        released = true;
        if (owner !is null)
            owner.releaseReservation(directory, bytes);
    }

    /// Release the reservation when it leaves scope.
    ~this()
    {
        release();
    }
}

/** Session-scoped, budgeted staging area for bulk archive extraction.
 *
 * The class mirrors the member cache's session and stale-session handling, but
 * it deliberately has no per-member index and no LRU. Reservations are made
 * for whole archives and released when the archive scan finishes.
 */
final class ArchiveBulkStaging
{
private:
    /// Guards reservations and session state.
    Mutex mutex;
    /// Directory of this staging session.
    string sessionRoot;
    /// Exclusive lock that keeps stale-session cleanup from removing this session.
    TargetWriteLease sessionLease;
    /// Hard limit for concurrently reserved staging bytes.
    ulong maximumBytes;
    /// Bytes currently reserved by live reservations.
    ulong reservedBytes;
    /// Monotonic counter used to make reservation directories unique.
    size_t serial;
    /// True once `close()` disposed the session.
    bool closed;

public:
    /** Create a staging session below `root`.
     *
     * Params:
     *     root = Parent directory; an empty string selects the system
     *         temporary directory.
     *     byteLimit = Hard reservation limit; zero derives it from available
     *         space.
     * Throws: `Exception` when the session directory or lease cannot be
     *     created, or when no positive limit can be derived.
     */
    this(string root = "", ulong byteLimit = 0)
    {
        mutex = new Mutex();
        if (root.length == 0)
            root = buildPath(tempDir(), "dosierskanilo-archive-staging");
        mkdirRecurse(root);
        cleanupStaleSessions(root);
        sessionRoot = buildPath(root, "session-" ~ thisProcessID.to!string
            ~ "-" ~ randomUUID().toString());
        sessionLease = TargetWriteLease.acquireRepositoryRoot(sessionRoot);
        cleanupStaleSessions(root);
        mkdirRecurse(sessionRoot);
        maximumBytes = byteLimit > 0 ? byteLimit
            : defaultArchiveStagingByteLimitFor(root);
        if (maximumBytes == 0)
            throw new Exception("Archive staging byte limit must be positive.");
    }

    /** Reserve staging space for one archive extraction.
     *
     * Params:
     *     bytes = Estimated uncompressed bytes, including slack.
     * Returns: A reservation with a unique directory, or `null` when the
     *     configured budget or current free space is insufficient.
     * Throws: `Exception` after `close()`.
     */
    ArchiveBulkReservation reserve(ulong bytes)
    {
        if (bytes == 0)
            return null;
        string directory;
        synchronized (mutex)
        {
            if (closed)
                throw new Exception("Archive staging session is closed.");
            if (bytes > maximumBytes)
                return null;
            if (ulong.max - reservedBytes < bytes)
                return null;
            if (reservedBytes + bytes > maximumBytes)
                return null;
            const free = availableBytes(sessionRoot);
            if (free == 0 || bytes > free / 2)
                return null;
            directory = buildPath(sessionRoot,
                (++serial).to!string ~ "-" ~ randomUUID().toString());
            mkdirRecurse(directory);
            reservedBytes += bytes;
        }
        return new ArchiveBulkReservation(this, directory, bytes);
    }

    /** Release one reservation and remove its staging tree.
     *
     * Params:
     *     directory = Reservation directory returned by `reserve()`.
     *     bytes = Reservation size returned by `reserve()`.
     */
    void releaseReservation(string directory, ulong bytes)
    {
        synchronized (mutex)
        {
            if (bytes > reservedBytes)
                reservedBytes = 0;
            else
                reservedBytes -= bytes;
        }
        if (directory.length > 0 && exists(directory))
            try
                rmdirRecurse(directory);
            catch (Exception)
            {
            }
    }

    /// Return the session root, primarily for diagnostics and tests.
    @property string rootPath() const @safe
    {
        return sessionRoot;
    }

    /// Return the configured staging byte limit.
    @property ulong byteLimit() const @safe
    {
        return maximumBytes;
    }

    /// Return the currently reserved staging bytes.
    @property ulong currentReservedBytes() const @safe
    {
        synchronized (mutex)
            return reservedBytes;
    }

    /** Close the session and remove its staging tree.
     *
     * Throws: `Exception` while reservations are still live. Callers must
     *     release archive reservations before closing.
     */
    void close()
    {
        synchronized (mutex)
        {
            if (closed)
                return;
            if (reservedBytes != 0)
                throw new Exception(
                    "Archive staging session still has live reservations.");
            closed = true;
        }
        scope (exit)
            sessionLease.release();
        if (exists(sessionRoot))
            rmdirRecurse(sessionRoot);
    }

    /// Remove the session directory on destruction when no reservation blocks it.
    ~this()
    {
        try
            close();
        catch (Exception)
        {
        }
    }

private:
    /** Remove session directories left behind by exited processes.
     *
     * Params:
     *     root = Staging parent directory scanned one level deep.
     */
    void cleanupStaleSessions(string root)
    {
        foreach (DirEntry entry; dirEntries(root, SpanMode.shallow))
        {
            if (!isDir(entry.name)
                || !entry.name.baseName.startsWith("session-"))
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
            if (exists(entry.name))
                try
                    rmdirRecurse(entry.name);
                catch (Exception)
                {
                }
        }
    }
}

/// Spin lock that guards the process-wide staging pointer.
private shared int sharedBulkGuard;
/// Process-wide staging instance, or `null` when none exists yet.
private __gshared ArchiveBulkStaging processBulkStaging;

/** Acquire the process-wide staging guard. */
private void lockSharedBulkGuard()
{
    import core.atomic : cas;
    import core.thread : Thread;

    while (!cas(&sharedBulkGuard, 0, 1))
        Thread.yield();
}

/** Release the process-wide staging guard. */
private void unlockSharedBulkGuard()
{
    import core.atomic : atomicStore;

    atomicStore(sharedBulkGuard, 0);
}

/** Return the process-wide staging session, creating it lazily.
 *
 * Returns: The shared staging session.
 */
ArchiveBulkStaging sharedArchiveBulkStaging()
{
    lockSharedBulkGuard();
    scope (exit)
        unlockSharedBulkGuard();
    if (processBulkStaging is null)
        processBulkStaging = new ArchiveBulkStaging();
    return processBulkStaging;
}

/** Replace the process-wide staging session with an explicitly configured one.
 *
 * Must be called before archive workers start.
 *
 * Params:
 *     root = Parent directory; empty selects the system temporary directory.
 *     byteLimit = Reservation limit in bytes; zero derives it from free space.
 */
void configureSharedArchiveBulkStaging(string root, ulong byteLimit)
{
    lockSharedBulkGuard();
    scope (exit)
        unlockSharedBulkGuard();
    if (processBulkStaging !is null)
    {
        processBulkStaging.close();
        processBulkStaging = null;
    }
    processBulkStaging = new ArchiveBulkStaging(root, byteLimit);
}

/** Close and remove the process-wide staging session.
 *
 * Returns: `true` when the session was closed or none existed; `false` when
 *     live reservations or filesystem errors block the close.
 */
bool closeSharedArchiveBulkStaging()
{
    lockSharedBulkGuard();
    scope (exit)
        unlockSharedBulkGuard();
    if (processBulkStaging is null)
        return true;
    try
        processBulkStaging.close();
    catch (Exception)
        return false;
    processBulkStaging = null;
    return true;
}

@("staging reservations respect the byte budget")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "archive-staging-budget-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto staging = new ArchiveBulkStaging(root, 4096);
    scope (exit)
        if (exists(staging.rootPath))
            staging.close();
    auto first = staging.reserve(3072);
    assert(first !is null);
    assert(staging.currentReservedBytes == 3072);
    assert(staging.reserve(2048) is null,
        "the staging budget must not be oversubscribed");
    const firstPath = first.path;
    first.release();
    assert(staging.currentReservedBytes == 0);
    assert(!exists(firstPath),
        "releasing a reservation must remove its staging tree");
    auto second = staging.reserve(2048);
    assert(second !is null);
    second.release();
}
