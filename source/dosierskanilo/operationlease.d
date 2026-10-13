/** Cross-process exclusive write leases for operation targets. */
module dosierskanilo.operationlease;

import std.file : mkdirRecurse, tempDir;
import std.format : format;
import std.path : absolutePath, buildNormalizedPath, buildPath;

import dosierskanilo.operations : OperationTarget, OperationStorageMode;

/** A failure category reserved for an already-leased operation target. */
class OperationTargetBusyException : Exception
{
    this(string target)
    {
        super("Another mutating operation already owns target: " ~ target);
    }
}

/** Advisory operating-system lock held for the full lifetime of one operation. */
final class TargetWriteLease
{
private:
    int descriptor = -1;
    string leasedTargetKey;

    this(string lockPath, string targetKey)
    {
        leasedTargetKey = targetKey;
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, 0x40 | 0x02, 384);
            if (descriptor < 0)
                throw new Exception("Unable to open operation lease file.");
            if (cFlock(descriptor, 0x02 | 0x04) != 0)
            {
                auto error = *cErrnoLocation();
                cClose(descriptor);
                descriptor = -1;
                if (error == 11)
                    throw new OperationTargetBusyException(targetKey);
                throw new Exception(format("Unable to acquire operation lease (errno %d).",
                    error));
            }
        }
        else
            throw new Exception("Cross-process operation leases are unsupported on this platform.");
    }

public:
    /** Acquire a lease for the canonical repository root or JSON catalog path. */
    static TargetWriteLease acquire(OperationTarget target)
    {
        auto targetKey = canonicalTargetKey(target);
        return new TargetWriteLease(operationLockPath(targetKey), targetKey);
    }

    /** Acquire a repository lease when the caller already resolved its root. */
    static TargetWriteLease acquireRepositoryRoot(string rootPath)
    {
        return acquire(OperationTarget.repositoryTarget(rootPath));
    }

    /** Whether this lease protects the supplied normalized operation target. */
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
                cFlock(descriptor, 0x08);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    ~this()
    {
        release();
    }
}

/** Shared read lease that waits for an active JSON replacement to finish. */
final class TargetReadLease
{
private:
    int descriptor = -1;

    this(string lockPath)
    {
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, 0x40 | 0x02, 384);
            if (descriptor < 0)
                throw new Exception("Unable to open operation lease file.");
            if (cFlock(descriptor, 0x01) != 0)
            {
                auto error = *cErrnoLocation();
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
    /** Acquire a shared lease for a JSON catalog while parsing its current contents. */
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
                cFlock(descriptor, 0x08);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    ~this()
    {
        release();
    }
}

/** Exclusive short-lived lease protecting the JSON backup/replacement sequence. */
final class TargetCatalogReplacementLease
{
private:
    int descriptor = -1;

    this(string lockPath, string targetKey, bool wait)
    {
        version (Posix)
        {
            import std.string : toStringz;
            descriptor = cOpen(lockPath.toStringz, 0x40 | 0x02, 384);
            if (descriptor < 0)
                throw new Exception("Unable to open catalog replacement lease file.");
            auto flags = 0x02 | (wait ? 0 : 0x04);
            if (cFlock(descriptor, flags) != 0)
            {
                auto error = *cErrnoLocation();
                cClose(descriptor);
                descriptor = -1;
                if (error == 11)
                    throw new OperationTargetBusyException(targetKey);
                throw new Exception(format("Unable to acquire catalog replacement lease (errno %d).",
                    error));
            }
        }
        else
            throw new Exception("Cross-process catalog leases are unsupported on this platform.");
    }

public:
    /** Acquire exclusive access only for the non-interruptible replacement phase. */
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
                cFlock(descriptor, 0x08);
                cClose(descriptor);
            }
            descriptor = -1;
        }
    }

    ~this()
    {
        release();
    }
}

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

private string operationLockPath(string targetKey)
{
    auto directory = buildPath(tempDir(), "dosierskanilo-operation-leases");
    mkdirRecurse(directory);
    return buildPath(directory, "operation-" ~ targetLockName(targetKey) ~ ".lock");
}

private string catalogLockPath(string targetKey)
{
    auto directory = buildPath(tempDir(), "dosierskanilo-operation-leases");
    mkdirRecurse(directory);
    return buildPath(directory, "catalog-" ~ targetLockName(targetKey) ~ ".lock");
}

version (Posix)
{
    pragma(mangle, "open") extern (C) nothrow int cOpen(const(char)* path,
        int flags, ...);
    pragma(mangle, "flock") extern (C) nothrow int cFlock(int fd, int operation);
    pragma(mangle, "close") extern (C) nothrow int cClose(int fd);
    pragma(mangle, "__errno_location") extern (C) nothrow int* cErrnoLocation();
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
