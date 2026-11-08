/** Cross-process advisory leases for operation targets: exclusive writes,
 * shared JSON reads, and short-lived catalog-replacement locks.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.operationlease;

import std.file : mkdirRecurse, tempDir;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath, buildPath;
import std.process : environment;

version (Posix)
{
    import core.stdc.errno : EAGAIN, EWOULDBLOCK, errno;
    import core.sys.posix.fcntl : O_CREAT, O_RDWR;
    import core.sys.posix.sys.stat : chmod, mode_t;
    import core.sys.posix.unistd : getuid;
}

import dosierskanilo.operations : OperationTarget, OperationStorageMode;

/** A failure category reserved for an already-leased operation target. */
class OperationTargetBusyException : Exception
{
    /** Build the exception for a target that another operation owns.
     *
     * Params:
     *     target = Canonical target key included in the message.
     */
    this(string target)
    {
        super("Another mutating operation already owns target: " ~ target);
    }
}

/** Advisory operating-system lock held for the full lifetime of one operation. */
final class TargetWriteLease
{
private:
    /// Operating-system file descriptor for the lock, or `-1` when released.
    int descriptor = -1;
    /// Canonical key of the target protected by this lease.
    string leasedTargetKey;

    /** Open and exclusively lock the lease file for a target.
     *
     * Params:
     *     lockPath = Filesystem path of the lease file.
     *     targetKey = Canonical target key used for diagnostics and ownership.
     * Throws: `OperationTargetBusyException` when another process already
     *     holds the lease, or `Exception` when the lock file cannot be opened
     *     or the platform does not support leases.
     */
    this(string lockPath, string targetKey)
    {
        leasedTargetKey = targetKey;
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, O_RDWR | O_CREAT, 384 /* 0600 */);
            if (descriptor < 0)
                throw new Exception("Unable to open operation lease file.");
            if (cFlock(descriptor, LOCK_EX | LOCK_NB) != 0)
            {
                auto error = errno;
                cClose(descriptor);
                descriptor = -1;
                if (error == EAGAIN || error == EWOULDBLOCK)
                    throw new OperationTargetBusyException(targetKey);
                throw new Exception(format("Unable to acquire operation lease (errno %d).",
                    error));
            }
        }
        else
            throw new Exception("Cross-process operation leases are unsupported on this platform.");
    }

public:
    /** Acquire a lease for the canonical repository root or JSON catalog path.
     *
     * Params:
     *     target = Operation target to protect.
     * Returns: A held lease; release it when the operation ends.
     * Throws: `OperationTargetBusyException` when another process owns the
     *     target, or `Exception` when the lease file cannot be opened.
     */
    static TargetWriteLease acquire(OperationTarget target)
    {
        auto targetKey = canonicalTargetKey(target);
        return new TargetWriteLease(operationLockPath(targetKey), targetKey);
    }

    /** Acquire a repository lease when the caller already resolved its root.
     *
     * Params:
     *     rootPath = Repository root directory.
     * Returns: A held lease; release it when the operation ends.
     * Throws: `OperationTargetBusyException` when another process owns the
     *     target, or `Exception` when the lease file cannot be opened.
     */
    static TargetWriteLease acquireRepositoryRoot(string rootPath)
    {
        return acquire(OperationTarget.repositoryTarget(rootPath));
    }

    /** Whether this lease protects the supplied normalized operation target.
     *
     * Params:
     *     target = Target to compare against the leased target.
     * Returns: `true` when both normalize to the same lock key.
     */
    bool owns(OperationTarget target)
    {
        return leasedTargetKey == canonicalTargetKey(target);
    }

    /** Release the operating-system lock. Idempotent. */
    void release() nothrow
    {
        if (descriptor >= 0)
        {
            version (Posix)
            {
                cFlock(descriptor, LOCK_UN);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    /** Release the lease when the object is destroyed. */
    ~this()
    {
        release();
    }
}

/** Shared read lease that waits for an active JSON replacement to finish. */
final class TargetReadLease
{
private:
    /// Operating-system file descriptor for the lock, or `-1` when released.
    int descriptor = -1;

    /** Open and acquire a shared lock on a JSON catalog lease file.
     *
     * Params:
     *     lockPath = Filesystem path of the lease file.
     * Throws: `Exception` when the lock file cannot be opened or the lock
     *     cannot be acquired, including on platforms without lease support.
     */
    this(string lockPath)
    {
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, O_RDWR | O_CREAT, 384 /* 0600 */);
            if (descriptor < 0)
                throw new Exception("Unable to open operation lease file.");
            if (cFlock(descriptor, LOCK_SH) != 0)
            {
                auto error = errno;
                cClose(descriptor);
                descriptor = -1;
                throw new Exception(format("Unable to acquire JSON read lease (errno %d).",
                    error));
            }
        }
        else
            throw new Exception("Cross-process operation leases are unsupported on this platform.");
    }

public:
    /** Acquire a shared lease for a JSON catalog while parsing its current contents.
     *
     * Params:
     *     catalogPath = Path of the JSON catalog.
     * Returns: A held shared lease; release it after parsing.
     * Throws: `Exception` when the lease file cannot be opened or locked.
     */
    static TargetReadLease acquireJsonCatalog(string catalogPath)
    {
        auto targetKey = canonicalTargetKey(
            OperationTarget.jsonTarget(catalogPath));
        return new TargetReadLease(catalogLockPath(targetKey));
    }

    /** Release the shared operating-system lock. Idempotent. */
    void release() nothrow
    {
        if (descriptor >= 0)
        {
            version (Posix)
            {
                cFlock(descriptor, LOCK_UN);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    /** Release the read lease when the object is destroyed. */
    ~this()
    {
        release();
    }
}

/** Exclusive short-lived lease protecting the JSON backup/replacement sequence. */
final class TargetCatalogReplacementLease
{
private:
    /// Operating-system file descriptor for the lock, or `-1` when released.
    int descriptor = -1;

    /** Open and acquire the catalog replacement lock.
     *
     * Params:
     *     lockPath = Filesystem path of the lease file.
     *     targetKey = Canonical target key used for diagnostics.
     *     wait = Whether to block until the lock becomes available instead of
     *         failing immediately.
     * Throws: `OperationTargetBusyException` when the lock is held and `wait`
     *     is false, or `Exception` when the file cannot be opened or the lock
     *     fails for another reason.
     */
    this(string lockPath, string targetKey, bool wait)
    {
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, O_RDWR | O_CREAT, 384 /* 0600 */);
            if (descriptor < 0)
                throw new Exception("Unable to open catalog replacement lease file.");
            auto flags = LOCK_EX | (wait ? 0 : LOCK_NB);
            if (cFlock(descriptor, flags) != 0)
            {
                auto error = errno;
                cClose(descriptor);
                descriptor = -1;
                if (error == EAGAIN || error == EWOULDBLOCK)
                    throw new OperationTargetBusyException(targetKey);
                throw new Exception(format("Unable to acquire catalog replacement lease (errno %d).",
                    error));
            }
        }
        else
            throw new Exception("Cross-process catalog leases are unsupported on this platform.");
    }

public:
    /** Acquire exclusive access only for the non-interruptible replacement phase.
     *
     * Params:
     *     catalogPath = Path of the JSON catalog.
     *     wait = Whether to block until the lock is available instead of
     *         failing immediately.
     * Returns: A held replacement lease; release it after the replacement.
     * Throws: `OperationTargetBusyException` when the lock is held and `wait`
     *     is false, or `Exception` when the lease file cannot be opened or
     *     locked.
     */
    static TargetCatalogReplacementLease acquireJsonCatalog(string catalogPath,
        bool wait = true)
    {
        auto targetKey = canonicalTargetKey(
            OperationTarget.jsonTarget(catalogPath));
        return new TargetCatalogReplacementLease(catalogLockPath(targetKey),
            targetKey, wait);
    }

    /** Release the exclusive replacement lock. Idempotent. */
    void release() nothrow
    {
        if (descriptor >= 0)
        {
            version (Posix)
            {
                cFlock(descriptor, LOCK_UN);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    /** Release the replacement lease when the object is destroyed. */
    ~this()
    {
        release();
    }
}

/** Derive a stable lock key from a normalized operation target.
 *
 * Params:
 *     target = Operation target to normalize.
 * Returns: A key of the form `repository:<root>` or `json:<catalogPath>`.
 */
private string canonicalTargetKey(OperationTarget target)
{
    final switch (target.mode)
    {
    case OperationStorageMode.repository:
        auto root = buildNormalizedPath(absolutePath(target.repositoryRoot));
        return "repository:" ~ root;
    case OperationStorageMode.jsonCatalog:
        return "json:" ~ buildNormalizedPath(absolutePath(target.catalogPath));
    }
}

/** Compute a fixed-width hexadecimal lock file name from a target key.
 *
 * Params:
 *     targetKey = Canonical operation target key.
 * Returns: A 32-character hexadecimal name derived from two independent
 *     hashes of the key.
 */
private string targetLockName(string targetKey)
{
    ulong first = 14695981039346656037UL;
    ulong second = 1099511628211UL;
    foreach (character; cast(const(ubyte)[]) targetKey)
    {
        first = (first ^ character) * 1099511628211UL;
        second = (second ^ (character + 0x9d)) * 14695981039346656037UL;
    }
    return format("%016x%016x", first, second);
}

/** Return the private directory that stores operation lease files.
 *
 * Uses `XDG_RUNTIME_DIR` when available, otherwise a per-user directory below
 * the system temporary directory. The directory is created with owner-only
 * permissions where supported.
 *
 * Returns: Absolute path of the lease directory.
 */
private string lockDirectory()
{
    version (Posix)
    {
        const runtime = environment.get("XDG_RUNTIME_DIR", null);
        const directory = runtime.length > 0
            ? buildPath(runtime, "dosierskanilo-operation-leases")
            : buildPath(tempDir(), "dosierskanilo-operation-leases-"
                ~ format("%d", getuid()));
        import std.string : toStringz;

        mkdirRecurse(directory);
        /* Keep lock files private when the fallback temp directory is shared. */
        chmod(directory.toStringz, cast(mode_t) 448 /* 0700 */);
        return directory;
    }
    else
        return buildPath(tempDir(), "dosierskanilo-operation-leases");
}

/** Return the exclusive operation lease file path for a target key.
 *
 * Params:
 *     targetKey = Canonical operation target key.
 * Returns: Absolute path of the operation lock file.
 */
private string operationLockPath(string targetKey)
{
    return buildPath(lockDirectory(),
        "operation-" ~ targetLockName(targetKey) ~ ".lock");
}

/** Return the catalog replacement/read lease file path for a target key.
 *
 * Params:
 *     targetKey = Canonical JSON catalog target key.
 * Returns: Absolute path of the catalog lock file.
 */
private string catalogLockPath(string targetKey)
{
    return buildPath(lockDirectory(),
        "catalog-" ~ targetLockName(targetKey) ~ ".lock");
}

version (Posix)
{
    /* sys/file.h defines the same lock operation values on Linux, the BSDs and
     * macOS; druntime does not declare flock() or these constants. */
    /// Request a shared (read) lock.
    enum LOCK_SH = 0x01;
    /// Request an exclusive (write) lock.
    enum LOCK_EX = 0x02;
    /// Fail instead of waiting when the lock is not immediately available.
    enum LOCK_NB = 0x04;
    /// Release a lock held on a file descriptor.
    enum LOCK_UN = 0x08;

    /** C binding for the POSIX `open` function.
     *
     * Params:
     *     path = NUL-terminated filesystem path.
     *     flags = Open flags such as `O_RDWR` and `O_CREAT`.
     * Returns: A non-negative file descriptor, or `-1` on error.
     */
    pragma(mangle, "open") extern (C) nothrow int cOpen(const(char)* path,
        int flags, ...);
    /** C binding for the BSD/POSIX `flock` function.
     *
     * Params:
     *     fd = Open file descriptor.
     *     operation = Lock operation such as `LOCK_EX` or `LOCK_UN`.
     * Returns: Zero on success, or `-1` on error.
     */
    pragma(mangle, "flock") extern (C) nothrow int cFlock(int fd, int operation);
    /** C binding for the POSIX `close` function.
     *
     * Params:
     *     fd = File descriptor to close.
     * Returns: Zero on success, or `-1` on error.
     */
    pragma(mangle, "close") extern (C) nothrow int cClose(int fd);
}

@("operation target lease key is stable for the same canonical source")
unittest
{
    import std.file : mkdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-lease-key-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto first = OperationTarget.jsonTarget(buildPath(root, "catalog.json"));
    auto second = OperationTarget.jsonTarget(buildPath(root, ".", "catalog.json"));
    assert(canonicalTargetKey(first) == canonicalTargetKey(second));
    import std.file : rmdirRecurse;
    rmdirRecurse(root);
}

@("operation target lease excludes a concurrent writer and releases cleanly")
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-lease-lock-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto target = OperationTarget.jsonTarget(buildPath(root, "catalog.json"));
    auto lease = TargetWriteLease.acquire(target);
    auto readLease = TargetReadLease.acquireJsonCatalog(target.catalogPath);
    bool busy;
    try
        TargetCatalogReplacementLease.acquireJsonCatalog(target.catalogPath, false);
    catch (OperationTargetBusyException)
        busy = true;
    readLease.release();
    assert(busy);
    auto replacement = TargetCatalogReplacementLease.acquireJsonCatalog(
        target.catalogPath, false);
    replacement.release();
    lease.release();
    auto released = TargetWriteLease.acquire(target);
    released.release();
    rmdirRecurse(root);
}

version (Posix)
{
    /** C binding for the POSIX `fork` function used by the lease tests.
     *
     * Returns: The child pid in the parent, zero in the child, or a negative
     *     value on failure.
     */
    private extern(C) int fork();
}

version (Posix)
@("operation target lease excludes a second process")
unittest
{
    import core.sys.posix.signal : SIGKILL, kill;
    import core.sys.posix.sys.wait : waitpid;
    import core.sys.posix.unistd : _exit, sleep;
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.string : toStringz;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-lease-process-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto target = OperationTarget.repositoryTarget(root);
    auto lockPath = operationLockPath(canonicalTargetKey(target));
    auto lockPathz = lockPath.toStringz;

    const pid = fork();
    assert(pid >= 0, "Could not fork a lease-holding process.");
    if (pid == 0)
    {
        /* Only syscalls and sleep, so the child never needs the D runtime. */
        auto descriptor = cOpen(lockPathz, O_RDWR | O_CREAT, 384 /* 0600 */);
        if (descriptor < 0 || cFlock(descriptor, LOCK_EX | LOCK_NB) != 0)
            _exit(1);
        sleep(30);
        _exit(0);
    }

    bool busy;
    foreach (attempt; 0 .. 200)
    {
        try
        {
            auto contender = TargetWriteLease.acquire(target);
            contender.release();
        }
        catch (OperationTargetBusyException)
        {
            busy = true;
            break;
        }
        Thread.sleep(5.msecs);
    }

    kill(pid, SIGKILL);
    int status;
    waitpid(pid, &status, 0);
    rmdirRecurse(root);
    assert(busy, "The child process must keep the operation lease busy.");
}

@("JSON readers coexist with operation staging but exclude file replacement")
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-json-read-lease-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto target = OperationTarget.jsonTarget(buildPath(root, "catalog.json"));
    auto readLease = TargetReadLease.acquireJsonCatalog(target.catalogPath);
    auto writer = TargetWriteLease.acquire(target);
    bool busy;
    try
        TargetCatalogReplacementLease.acquireJsonCatalog(target.catalogPath, false);
    catch (OperationTargetBusyException)
        busy = true;
    readLease.release();
    assert(busy);
    auto replacement = TargetCatalogReplacementLease.acquireJsonCatalog(
        target.catalogPath, false);
    replacement.release();
    writer.release();
    rmdirRecurse(root);
}
