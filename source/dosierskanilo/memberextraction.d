/** Shared archive-member extraction over the leased member cache.
 *
 * Backends resolve typed container/entry chains and delegate the physical
 * extraction here so JSON and SQLite sources share one identity, password,
 * cancellation, and cleanup path.
 */
module dosierskanilo.memberextraction;

import core.atomic : atomicLoad;
import std.path : buildPath, isAbsolute;

import dosierarkivo.archive : ArchiveEntryDescriptor;
import dosierarkivo.factory : fileArchive;
import dosierskanilo.catalogbackend : CatalogBackendErrorCode,
    CatalogBackendException, ContentId, ContentLocator;
import dosierskanilo.membercontentcache : MemberContentLease,
    sharedMemberContentCache;

/** One container-to-member layer of a nested archive extraction. */
struct ArchiveExtractionStep
{
    string memberPath; /// Normalized member path inside the current container.
    size_t occurrence; /// Duplicate-name occurrence, zero when unique.
    string password; /// Password for the current container, empty when none.
    ContentLocator locator; /// Typed identity of the extracted member.
    ulong knownSize; /// Known uncompressed size, zero when unknown.
}

/**
 * Extract a member chain and return the final leased cache file.
 *
 * Params:
 *     sourceRoot = Filesystem root that owns the physical container.
 *     containerRelativePath = Physical container path relative to `sourceRoot`,
 *         or an absolute path for JSON catalogs without a filesystem root.
 *     steps = Ordered extraction layers, outermost container first.
 *     cancellation = Optional cooperative cancellation flag.
 * Returns: The lease of the final extracted member; the caller must release it.
 * Throws: `CatalogBackendException` when a container or member is unavailable;
 *     cache exceptions propagate unchanged.
 */
MemberContentLease extractArchiveMember(string sourceRoot,
    string containerRelativePath, ArchiveExtractionStep[] steps,
    shared(bool)* cancellation = null)
{
    if (steps.length == 0)
        throw new CatalogBackendException(
            CatalogBackendErrorCode.invalidIdentifier,
            "Archive member extraction requires at least one entry step.");
    auto containerPath = isAbsolute(containerRelativePath)
        ? containerRelativePath : buildPath(sourceRoot, containerRelativePath);
    MemberContentLease previousLease;
    scope (failure)
        if (previousLease !is null)
            previousLease.release();
    foreach (index; 0 .. steps.length)
    {
        const auto step = steps[index];
        auto archive = fileArchive(containerPath);
        if (archive is null)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "The archive adapter for the selected container is unavailable.");
        auto descriptors = archive.getEntryDescriptors(step.password);
        if (descriptors is null)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "The archive adapter could not list member descriptors.");
        ArchiveEntryDescriptor selected;
        bool found;
        foreach (descriptor; descriptors)
            if (descriptor.hasSafePath && !descriptor.isDirectory
                && descriptor.relativePath == step.memberPath
                && descriptor.occurrence == step.occurrence)
            {
                selected = descriptor;
                found = true;
                break;
            }
        if (!found)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "The selected archive member is no longer present.");
        const bool isFinal = index + 1 == steps.length;
        const auto sizeLimit = selected.hasSize ? selected.size
            : isFinal ? step.knownSize : 0;
        const auto fallbackIdentity = "extraction:"
            ~ step.locator.archiveEntry.containerReferenceId.adapterToken
            ~ ":" ~ step.locator.archiveEntry.entryId.adapterToken;
        auto lease = sharedMemberContentCache().acquire(step.locator,
            ContentId.init, fallbackIdentity, step.memberPath, sizeLimit,
            (string destinationDirectory) {
                if (cancellation !is null && atomicLoad(*cancellation))
                    return false;
                return archive.extractEntry(selected, destinationDirectory,
                    step.password);
            }, cancellation);
        if (previousLease !is null)
            previousLease.release();
        previousLease = lease;
        containerPath = lease.path;
    }
    return previousLease;
}
