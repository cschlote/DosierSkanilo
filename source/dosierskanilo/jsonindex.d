/** Index construction members of `JsonCatalogBackend`.
 *
 *
 * The index maps references, directories, archive members, and content tokens
 * from the JSON catalog document.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsonindex;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.file : exists, timeLastModified;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    isAbsolute, dirName, isAbsolute;
import std.string : split;
import dosierarkivo.archive : appendArchiveVirtualPath, archiveDisplayBaseName,
    escapeArchiveVirtualPath, nativePathToStoragePath,
    normalizeArchiveEntryPath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.logging : logLineVerbose;
import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    NamedBinaryBlob;
import dosierskanilo.operationrunner;
import dosierskanilo.jsoncatalogbackend : JsonLocation, V5JsonReference;

/** Members of `JsonCatalogBackend` mixed into the class; see jsonindex.d. */
mixin template JsonIndexBuilding()
{
    /**
     * Express a stored file name relative to the bound filesystem root.
     *
     * Absolute names inside the root lose the root prefix. Names outside the root
     * or without a bound root are still normalized and returned as stored.
     *
     * Params:
     *     fileName = Stored file name, possibly absolute.
     * Returns: Normalized path relative to the source root when possible.
     */
    package string storageRelativePath(string fileName) const
    {
        if (!isAbsolute(fileName))
            return buildNormalizedPath(fileName);
        const auto root = backendTarget.filesystemRoot;
        if (root.length == 0)
            return buildNormalizedPath(fileName);
        const auto normalizedRoot = buildNormalizedPath(absolutePath(root));
        const auto normalizedPath = buildNormalizedPath(absolutePath(fileName));
        if (normalizedPath.startsWith(normalizedRoot ~ "/"))
            return normalizedPath[normalizedRoot.length + 1 .. $];
        return normalizedPath;
    }

    /**
     * Fill missing metadata in an export target from a candidate blob.
     *
     * Existing checksums, file type, media signature, archive specifications,
     * archive password, and torrent info are kept; missing values are copied.
     *
     * Params:
     *     target = Blob being assembled for export; updated in place.
     *     candidate = Blob providing fallback metadata.
     */
    package void mergeExportMetadata(ref NamedBinaryBlob target, NamedBinaryBlob candidate)
    {
        if (!target.checkSums.hasDigests && candidate.checkSums.hasDigests)
            target.checkSums = candidate.checkSums;
        if (target.fileType.length == 0)
            target.fileType = candidate.fileType;
        if ((target.mediaInfoSig is null
                || !hasAnyMediaStream(target.mediaInfoSig))
            && candidate.mediaInfoSig !is null)
            target.mediaInfoSig = candidate.mediaInfoSig.dup;
        if (target.archiveSpecs is null && candidate.archiveSpecs !is null)
            target.archiveSpecs = candidate.archiveSpecs.dup;
        target.archiveIndexKnown = target.archiveIndexKnown
            || candidate.archiveIndexKnown;
        if (target.archivePassword.length == 0)
            target.archivePassword = candidate.archivePassword;
        if (target.torrentInfo is null && candidate.torrentInfo !is null)
            target.torrentInfo = candidate.torrentInfo.dup;
    }

    /**
     * Resolve a stored file name into a catalog location.
     *
     * Version-5 names may contain archive virtual layers. Older writers sometimes
     * double-escaped a container separator; when the literal path does not exist
     * on disk, the value is folded back into an archive reference.
     *
     * Params:
     *     fileName = File name as stored in a catalog file specification.
     *     parseVirtual = Whether to parse archive virtual path syntax.
     * Returns: The resolved location; unbound or out-of-root paths carry a
     *     distinct `identityKey` prefix and leave tree fields unset.
     */
    package JsonLocation resolvePath(string fileName, bool parseVirtual = false) const
    {
        JsonLocation result;
        auto input = nativePathToStoragePath(fileName);
        auto physicalInput = input;
        if (parseVirtual)
        {
            auto parsed = parseArchiveVirtualPath(input);
            physicalInput = parsed.physicalPath;
            result.isVirtual = parsed.isVirtual;
            result.virtualEntries = parsed.entries;
            /* Historical JSON writers always used `!`; keep checking that
             * literal for old files even if the grammar constant changes. */
            if (!parsed.isVirtual && parsed.physicalPath.canFind('!'))
            {
                /* Older writers stored some archive members with the whole
                 * virtual path escaped twice (`container!!/member`). Decoded,
                 * the physical path then contains an archive separator. When
                 * no such literal path exists on disk, fold it back into the
                 * archive reference instead of exposing a phantom directory. */
                ParsedArchiveVirtualPath reinterpreted;
                bool doubleEscaped;
                try
                {
                    reinterpreted = parseArchiveVirtualPath(parsed.physicalPath);
                    doubleEscaped = reinterpreted.isVirtual;
                }
                catch (Exception)
                {
                }
                if (doubleEscaped)
                {
                    auto literalPath = parsed.physicalPath;
                    if (!isAbsolute(literalPath) && sourceRoot.length > 0)
                        literalPath = buildPath(sourceRoot, literalPath);
                    bool literalExists;
                    try
                        literalExists = exists(literalPath);
                    catch (Exception)
                    {
                    }
                    if (!literalExists)
                    {
                        parsed = reinterpreted;
                        physicalInput = parsed.physicalPath;
                        result.isVirtual = true;
                        result.virtualEntries = parsed.entries;
                    }
                }
            }
        }
        string normalizedPhysical;
        string prefix;
        string physicalRelative;
        if (sourceRoot.length == 0)
        {
            normalizedPhysical = nativePathToStoragePath(buildNormalizedPath(physicalInput));
            physicalRelative = normalizedPhysical;
            result.physicalRelativePath = physicalRelative;
            result.isInSourceRoot = false;
            result.relativePath = escapeArchiveVirtualPath(physicalRelative);
            foreach (entry; result.virtualEntries)
                result.relativePath = appendArchiveVirtualPath(result.relativePath,
                    entry.relativePath, entry.hasOccurrence ? entry.occurrence
                        : size_t.max);
            result.identityKey = "unbound:" ~ result.relativePath;
            return result;
        }

        normalizedPhysical = isAbsolute(physicalInput)
            ? nativePathToStoragePath(buildNormalizedPath(physicalInput))
            : nativePathToStoragePath(buildNormalizedPath(buildPath(sourceRoot, physicalInput)));
        prefix = sourceRoot == "/" ? "/" : sourceRoot ~ "/";
        if (!normalizedPhysical.startsWith(prefix))
        {
            result.identityKey = "outside:" ~ normalizedPhysical;
            return result;
        }
        physicalRelative = normalizedPhysical[prefix.length .. $];
        try
            ContentLocator.file(physicalRelative);
        catch (CatalogBackendException)
        {
            result.identityKey = "outside:" ~ normalizedPhysical;
            return result;
        }
        result.relativePath = escapeArchiveVirtualPath(physicalRelative);
        result.physicalRelativePath = physicalRelative;
        foreach (entry; result.virtualEntries)
            result.relativePath = appendArchiveVirtualPath(result.relativePath,
                entry.relativePath, entry.hasOccurrence ? entry.occurrence
                    : size_t.max);
        result.identityKey = result.relativePath;
        result.isInSourceRoot = true;
        return result;
    }

    /**
     * Build a stable content key from a blob's size and complete digests.
     *
     * Params:
     *     blob = Blob supplying size and checksums.
     *     fingerprint = Fingerprint describing digest completeness.
     * Returns: A key such as `fingerprint:<size>:<md5>:<sha1>:<xxh64>`, or an
     *     empty string when the fingerprint is incomplete.
     */
    package string strongFingerprintKey(NamedBinaryBlob blob,
        CatalogContentFingerprint fingerprint) const
    {
        if (!fingerprint.complete)
            return "";
        return "fingerprint:" ~ blob.fileSize.to!string ~ ":"
            ~ blob.checkSums.md5sum_b64 ~ ":" ~ blob.checkSums.sha1sum_b64
            ~ ":" ~ blob.checkSums.xxh64sum_b64;
    }

    /**
     * Wrap a content token in a catalog content identity.
     *
     * Params:
     *     token = Content token.
     * Returns: The corresponding `ContentId`.
     */
    package ContentId contentIdFromToken(string token) const
    {
        return ContentId(token);
    }

    /**
     * Build a content fingerprint from a size and stored checksums.
     *
     * Params:
     *     size = Content size in bytes.
     *     checksums = Stored digest container.
     * Returns: A fingerprint whose `complete` flag is true only when all three
     *     digests decode to their expected lengths.
     */
    package CatalogContentFingerprint fingerprintFor(size_t size, CheckSums checksums) const
    {
        CatalogContentFingerprint fingerprint;
        fingerprint.size = size;
        bool digestsValid = true;
        try
        {
            auto md5 = checksums.get_md5sum;
            auto sha1 = checksums.get_sha1sum;
            auto xxh64 = checksums.get_xxh64;
            if (md5.length > 0)
                fingerprint.digests ~= CatalogDigest("md5", md5.dup);
            if (sha1.length > 0)
                fingerprint.digests ~= CatalogDigest("sha1", sha1.dup);
            if (xxh64.length > 0)
                fingerprint.digests ~= CatalogDigest("xxh64", xxh64.dup);
            digestsValid = md5.length == 16 && sha1.length == 20
                && xxh64.length == 8;
        }
        catch (Exception)
            digestsValid = false;
        fingerprint.complete = checksums.hasDigests && digestsValid;
        return fingerprint;
    }

    /**
     * Build a content fingerprint for a catalog blob.
     *
     * Params:
     *     blob = Blob supplying size and checksums.
     * Returns: The derived fingerprint.
     */
    package CatalogContentFingerprint fingerprintFor(NamedBinaryBlob blob) const
    {
        return fingerprintFor(blob.fileSize, blob.checkSums);
    }

    /**
     * Whether a media stream array contains a non-null entry.
     *
     * Params:
     *     streams = Stream array to inspect.
     * Returns: True when at least one stream reference is present.
     */
    package static bool anyStream(T)(T[] streams)
    {
        foreach (stream; streams)
            if (stream !is null)
                return true;
        return false;
    }

    /**
     * Whether a media signature contains at least one non-null stream.
     *
     * Params:
     *     signature = Media signature to inspect; may be null.
     * Returns: True when any image, video, audio, or text stream exists.
     */
    package static bool hasAnyMediaStream(MediaInfoSig signature)
    {
        return signature !is null
            && (anyStream(signature.imageStreams)
                || anyStream(signature.videoStreams)
                || anyStream(signature.audioStreams)
                || anyStream(signature.textStreams));
    }

    /** Drop every derived index and disable tree queries until a rebuild. */
    package void clearIndex()
    {
        fileRows = [];
        directoryRows = [];
        sizeAscendingOrder = null;
        sizeDescendingOrder = null;
        archiveMemberRowsByDirectory = null;
        contentByToken = null;
        archiveEntriesByToken = null;
        torrentEntriesByToken = null;
        blobIndexByRelativePath = null;
        blobIndexByContentToken = null;
        contentTokenByBlobIndex = null;
        fileSpecByRelativePath = null;
        directoryIndexByPath = null;
        treeQueriesAvailable = false;
        torrentEntryDetailsUnavailable = false;
    }

    /**
     * Rebuild all derived indexes from the in-memory catalog.
     *
     * Path maps carried over from the previous index are pruned to the current
     * paths, preserving stable identities where content is unchanged. Indexing
     * failures leave tree queries disabled rather than throwing.
     */
    package void rebuildIndex()
    {
        import core.time : MonoTime;

        const auto started = MonoTime.currTime;
        clearIndex();
        treeQueriesAvailable = sourceRoot.length > 0;
        bool[string] seenPaths;
        bool[string] seenReferencePaths;
        string[string] v5ContentTokenByPath;
        V5JsonReference[] v5References;
        ++indexGeneration;

        foreach (blobIndex, blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            JsonLocation[] locations;
            string[] pathKeys;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.length == 0)
                    continue;
                auto location = resolvePath(spec.fileName,
                    catalog.dataVersion == DATA_CLASS_VERSION5);
                location.spec = spec;
                locations ~= location;
                pathKeys ~= location.identityKey;
                seenPaths[location.identityKey] = true;
                if (sourceRoot.length > 0 && !location.isInSourceRoot)
                    treeQueriesAvailable = false;
            }
            if (locations.length == 0)
            {
                auto legacyPath = blob.getFirstFileName;
                if (legacyPath.length > 0)
                {
                    auto location = resolvePath(legacyPath,
                        catalog.dataVersion == DATA_CLASS_VERSION5);
                    location.spec = new FileSpec(legacyPath, blob.timeLastModified);
                    locations ~= location;
                    pathKeys ~= location.identityKey;
                    seenPaths[location.identityKey] = true;
                    if (sourceRoot.length > 0 && !location.isInSourceRoot)
                        treeQueriesAvailable = false;
                }
            }

            auto fingerprint = fingerprintFor(blob);
            auto strongKey = strongFingerprintKey(blob, fingerprint);
            auto contentToken = contentTokenFor(blob, pathKeys, strongKey, blobIndex);
            if (contentToken !in blobIndexByContentToken)
            {
                if (contentTokenByBlobIndex.length <= blobIndex)
                    contentTokenByBlobIndex.length = blobIndex + 1;
                contentTokenByBlobIndex[blobIndex] = contentToken;
                blobIndexByContentToken[contentToken] = blobIndex;
            }
            auto contentId = contentIdFromToken(contentToken);
            if (auto existing = contentToken in contentByToken)
                mergeContentSnapshot(*existing, snapshotFor(blob, contentId));
            else
                contentByToken[contentToken] = snapshotFor(blob, contentId);
            indexArchiveAndTorrent(blob, contentToken);
            if (blob.torrentInfo !is null && blob.torrentInfo.files is null)
                torrentEntryDetailsUnavailable = true;

            foreach (location; locations)
            {
                if (catalog.dataVersion == DATA_CLASS_VERSION5)
                    v5ContentTokenByPath[location.relativePath] = contentToken;
                if (location.isVirtual)
                {
                    V5JsonReference reference;
                    reference.relativePath = location.relativePath;
                    reference.physicalRelativePath = location.physicalRelativePath;
                    reference.contentToken = contentToken;
                    reference.entries = location.virtualEntries;
                    reference.size = cast(ulong) blob.fileSize;
                    reference.modifiedAt = location.spec.timeLastModified;
                    v5References ~= reference;
                    continue;
                }
                if (!location.isInSourceRoot)
                    continue;
                seenReferencePaths[location.relativePath] = true;
                if (auto previousIndex = location.relativePath
                    in blobIndexByRelativePath)
                {
                    if (*previousIndex != blobIndex)
                        treeQueriesAvailable = false;
                    continue;
                }
                addFileReference(blob, location.spec, location, contentId, blobIndex);
            }
        }
        if (catalog.dataVersion == DATA_CLASS_VERSION5)
            indexV5ArchiveReferences(v5References, v5ContentTokenByPath);
        prunePathMap(contentTokenByPath, seenPaths);
        prunePathMap(oldFingerprintByPath, seenPaths);
        prunePathMap(oldSizeByPath, seenPaths);
        prunePathMap(referenceTokenByPath, seenReferencePaths);
        fileRows.sort!((left, right) => left.relativePath < right.relativePath);
        directoryRows.sort!((left, right) => left.relativePath < right.relativePath);
        logLineVerbose("[json-index] blobs=", catalog.dataArray.length,
            " files=", fileRows.length, " dirs=", directoryRows.length,
            " elapsedMs=",
            cast(long) (MonoTime.currTime - started).total!"msecs");
    }

    /**
     * Drop entries whose keys are no longer present in a retained key set.
     *
     * Params:
     *     values = Associative array to prune in place.
     *     retained = Keys to keep.
     */
    package void prunePathMap(T)(ref T[string] values, bool[string] retained)
    {
        string[] removed;
        foreach (key; values.keys)
            if (key !in retained)
                removed ~= key;
        foreach (key; removed)
            values.remove(key);
    }

    /**
     * Fold deferred version-5 member references into their container indexes.
     *
     * Params:
     *     references = Member references collected during the blob pass.
     *     contentByPath = Content token by display path for version-5 containers.
     */
    package void indexV5ArchiveReferences(V5JsonReference[] references,
        string[string] contentByPath)
    {
        foreach (reference; references)
        {
            if (reference.entries.length == 0)
                continue;
            auto parentPath = escapeArchiveVirtualPath(
                reference.physicalRelativePath);
            foreach (entry; reference.entries[0 .. $ - 1])
                parentPath = appendArchiveVirtualPath(parentPath,
                    entry.relativePath, entry.hasOccurrence ? entry.occurrence
                        : size_t.max);
            auto parentToken = parentPath in contentByPath;
            if (parentToken is null)
                continue;

            auto entries = archiveEntriesByToken.get(*parentToken, []);
            const auto finalLayer = reference.entries[$ - 1];
            const auto occurrence = finalLayer.hasOccurrence
                ? finalLayer.occurrence : 0;
            CatalogArchiveEntry entry;
            entry.id = ArchiveEntryId(*parentToken ~ ":v5:"
                ~ finalLayer.relativePath ~ ":" ~ occurrence.to!string);
            entry.name = finalLayer.relativePath;
            entry.relativePath = finalLayer.relativePath;
            entry.index = entries.length;
            entry.occurrence = occurrence;
            entry.hasSafePath = true;
            entry.size = reference.size;
            entry.modifiedAt = reference.modifiedAt;
            entry.contentId = contentIdFromToken(reference.contentToken);
            if (auto content = reference.contentToken in contentByToken)
                entry.fingerprint = (*content).fingerprint;

            size_t existingIndex = size_t.max;
            foreach (index, existing; entries)
                if (existing.relativePath == finalLayer.relativePath
                    && existing.occurrence == occurrence)
                {
                    existingIndex = index;
                    break;
                }
            if (existingIndex != size_t.max)
            {
                /* Duplicate member references (for example a stale
                 * zero-byte projection next to the indexed member) must not
                 * hide the reference that carries the real size or a
                 * complete fingerprint. */
                auto existing = entries[existingIndex];
                const bool richer = (entry.size > existing.size
                        && existing.size == 0)
                    || (entry.fingerprint.complete
                        && !existing.fingerprint.complete);
                if (!richer)
                    continue;
                entry.id = existing.id;
                entry.index = existing.index;
                entries[existingIndex] = entry;
            }
            else
                entries ~= entry;
            archiveEntriesByToken[*parentToken] = entries;

            if (auto parentContent = *parentToken in contentByToken)
            {
                parentContent.hasArchive = true;
                parentContent.archiveSummary.indexKnown = true;
                parentContent.archiveSummary.entryCount = entries.length;
                parentContent.archiveSummary.entriesWithCompleteFingerprints = 0;
                foreach (indexedEntry; entries)
                    if (indexedEntry.fingerprint.complete)
                        ++parentContent.archiveSummary.entriesWithCompleteFingerprints;
            }
            foreach (ref file; fileRows)
                if (file.contentId.adapterToken == *parentToken)
                    file.hasArchive = true;
        }
    }

    /**
     * Resolve or allocate a stable content token for a blob.
     *
     * Resolution order is: matching strong fingerprint, a previous token for one
     * of the paths whose size and fingerprint still agree, then a fresh token.
     *
     * Params:
     *     blob = Blob being indexed.
     *     paths = Identity keys of all locations for the blob.
     *     fingerprint = Strong fingerprint key, or an empty string when incomplete.
     *     blobIndex = Catalog array index, used for orphan blobs without paths.
     * Returns: The content token to use for the blob.
     */
    package string contentTokenFor(NamedBinaryBlob blob, string[] paths,
        string fingerprint, size_t blobIndex)
    {
        string token;
        if (fingerprint.length > 0)
            if (auto existing = fingerprint in contentTokenByFingerprint)
                token = *existing;

        foreach (path; paths)
        {
            if (token.length > 0)
                break;
            if (auto oldToken = path in contentTokenByPath)
            {
                ulong oldSize = ulong.max;
                if (auto storedSize = path in oldSizeByPath)
                    oldSize = *storedSize;
                string oldFingerprint;
                if (auto storedFingerprint = path in oldFingerprintByPath)
                    oldFingerprint = *storedFingerprint;
                if (oldSize == blob.fileSize
                    && (oldFingerprint.length == 0 || fingerprint.length == 0
                        || oldFingerprint == fingerprint))
                {
                    token = *oldToken;
                    break;
                }
            }
        }
        if (token.length == 0 && paths.length == 0)
        {
            auto key = "orphan:" ~ blobIndex.to!string ~ ":" ~ blob.fileSize.to!string;
            if (auto oldToken = key in contentTokenByFingerprint)
                token = *oldToken;
            else
                token = newContentToken();
            contentTokenByFingerprint[key] = token;
        }
        if (token.length == 0)
            token = newContentToken();
        if (fingerprint.length > 0)
            contentTokenByFingerprint[fingerprint] = token;
        foreach (path; paths)
        {
            contentTokenByPath[path] = token;
            oldFingerprintByPath[path] = fingerprint;
            oldSizeByPath[path] = blob.fileSize;
        }
        return token;
    }

    /**
     * Allocate a new unique content token for this backend instance.
     *
     * Returns: A token derived from the source token and identity counter.
     */
    package string newContentToken()
    {
        return sourceToken ~ ":content:" ~ (++nextIdentity).to!string;
    }

    /**
     * Return the stable reference token for a relative path.
     *
     * Params:
     *     relativePath = Relative path to identify.
     * Returns: The existing token, or a newly allocated one for the path.
     */
    package string referenceToken(string relativePath)
    {
        if (auto oldToken = relativePath in referenceTokenByPath)
            return *oldToken;
        auto token = sourceToken ~ ":reference:" ~ (++nextIdentity).to!string;
        referenceTokenByPath[relativePath] = token;
        return token;
    }

    /**
     * Index archive specifications and torrent file lists for one content token.
     *
     * Params:
     *     blob = Blob supplying archive and torrent metadata.
     *     contentToken = Content token that owns the metadata.
     */
    package void indexArchiveAndTorrent(NamedBinaryBlob blob, string contentToken)
    {
        if (blob.archiveIndexKnown && blob.archiveSpecs is null)
            archiveEntriesByToken[contentToken] = [];
        else
            indexArchiveSpecs(blob.archiveSpecs, contentToken);
        if (blob.torrentInfo !is null)
        {
            if (contentToken !in torrentEntriesByToken)
                torrentEntriesByToken[contentToken] = [];
            foreach (entry; blob.torrentInfo.files)
                if (entry !is null)
                {
                    bool alreadyIndexed;
                    if (auto existingEntries = contentToken in torrentEntriesByToken)
                        foreach (existing; *existingEntries)
                            if (existing.pathComponents == entry.path
                                && existing.size == entry.length)
                                alreadyIndexed = true;
                    if (!alreadyIndexed)
                        torrentEntriesByToken[contentToken] ~=
                            CatalogTorrentManifestEntry(entry.path.dup, entry.length);
                }
        }
    }

    /**
     * Recursively index archive specifications for one container content token.
     *
     * Each specification receives its index, occurrence, and entry identity;
     * linked member content is indexed as well.
     *
     * Params:
     *     specs = Archive entries to index; may be null.
     *     containerToken = Content token of the containing archive.
     *     depth = Current nesting depth; indexing stops beyond 32 levels.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.backendFailure` when nested archives exceed the
     *     depth limit.
     */
    package void indexArchiveSpecs(ArchiveSpec[] specs, string containerToken,
        size_t depth = 0)
    {
        if (depth >= 32)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "Nested JSON archive index exceeds the maximum depth.");
        if (specs !is null && containerToken !in archiveEntriesByToken)
            archiveEntriesByToken[containerToken] = [];
        size_t[string] occurrences;
        bool[string] indexedEntryIds;
        if (auto existingEntries = containerToken in archiveEntriesByToken)
            foreach (existing; *existingEntries)
                indexedEntryIds[existing.id.adapterToken] = true;
        foreach (index, spec; specs)
        {
            if (spec is null)
                continue;
            bool hasSafePath;
            bool isDirectory;
            auto relativePath = normalizeArchiveEntryPath(spec.fileName,
                hasSafePath, isDirectory);
            const auto identityPath = hasSafePath ? relativePath : spec.fileName;
            auto occurrenceKey = (hasSafePath ? "safe\0" : "unsafe\0")
                ~ identityPath;
            auto occurrence = occurrences.get(occurrenceKey, 0);
            occurrences[occurrenceKey] = occurrence + 1;
            spec.entryIndex = index;
            spec.occurrence = occurrence;
            spec.hasIndexIdentity = true;
            auto entryToken = containerToken ~ ":archive-v1:" ~ occurrenceKey
                ~ ":" ~ occurrence.to!string;

            string memberToken;
            auto fingerprint = fingerprintFor(spec.fileSize, spec.checkSums);
            if (hasSafePath && !isDirectory)
            {
                if (fingerprint.complete)
                {
                    const auto fingerprintKey = "fingerprint:"
                        ~ spec.fileSize.to!string ~ ":" ~ spec.checkSums.md5sum_b64
                        ~ ":" ~ spec.checkSums.sha1sum_b64 ~ ":"
                        ~ spec.checkSums.xxh64sum_b64;
                    if (auto existingToken = fingerprintKey in contentTokenByFingerprint)
                        memberToken = *existingToken;
                    else
                    {
                        memberToken = newContentToken();
                        contentTokenByFingerprint[fingerprintKey] = memberToken;
                    }
                }
                else
                    memberToken = containerToken ~ ":archive-content-v1:"
                        ~ occurrenceKey ~ ":" ~ occurrence.to!string;
            }

            CatalogArchiveEntry entry;
            entry.id = ArchiveEntryId(entryToken);
            entry.name = spec.fileName;
            entry.relativePath = relativePath;
            entry.index = index;
            entry.occurrence = occurrence;
            entry.isDirectory = isDirectory;
            entry.hasSafePath = hasSafePath;
            entry.size = cast(ulong) spec.fileSize;
            entry.modifiedAt = spec.timeLastModified;
            entry.fingerprint = fingerprint;
            if (memberToken.length > 0)
            {
                auto memberId = contentIdFromToken(memberToken);
                spec.contentBlobId = 0;
                spec.contentIdentity = memberToken;
                entry.contentId = memberId;
                auto memberSnapshot = snapshotForArchiveEntry(spec, memberId,
                    fingerprint);
                if (auto existingContent = memberToken in contentByToken)
                    mergeContentSnapshot(*existingContent, memberSnapshot);
                else
                    contentByToken[memberToken] = memberSnapshot;
                if (spec.nestedEntries !is null)
                    indexArchiveSpecs(spec.nestedEntries, memberToken, depth + 1);
            }
            if (entry.id.adapterToken !in indexedEntryIds)
            {
                archiveEntriesByToken[containerToken] ~= entry;
                indexedEntryIds[entry.id.adapterToken] = true;
            }
        }
    }

    /**
     * Ensure directory rows exist for a relative directory path.
     *
     * Missing intermediate directories are created and parent child counts are
     * updated. Empty paths and "." are ignored.
     *
     * Params:
     *     relativeDirectory = Directory path relative to the source root.
     */
    package void addDirectory(string relativeDirectory)
    {
        if (relativeDirectory.length == 0 || relativeDirectory == ".")
            return;
        string current;
        DirectoryId parent;
        foreach (part; relativeDirectory.split("/"))
        {
            current = current.length == 0 ? part : current ~ "/" ~ part;
            size_t index;
            if (auto existing = current in directoryIndexByPath)
                index = *existing;
            else
            {
                CatalogDirectory directory;
                directory.id = DirectoryId(sourceToken ~ ":directory:" ~ current);
                directory.parentId = parent;
                directory.name = archiveDisplayBaseName(part);
                directory.relativePath = current;
                index = directoryRows.length;
                directoryRows ~= directory;
                directoryIndexByPath[current] = index;
                if (parent.isValid)
                {
                    auto parentIndex = directoryIndexByPath[parentPath(current)];
                    directoryRows[parentIndex].childDirectoryCount++;
                }
            }
            parent = directoryRows[index].id;
        }
    }

    /**
     * Return the parent of a relative path, or an empty string at the root.
     *
     * Params:
     *     path = Relative path to inspect.
     * Returns: The parent path without a trailing separator.
     */
    package string parentPath(string path) const
    {
        auto parent = dirName(path);
        return parent == "." ? "" : parent;
    }

    /**
     * Add one physical file reference to the directory and file indexes.
     *
     * Duplicate paths are ignored; a conflicting content identity disables tree
     * queries. Directory counts and aggregate sizes are updated.
     *
     * Params:
     *     blob = Blob supplying content metadata.
     *     spec = File specification supplying the timestamp.
     *     location = Resolved location of the reference.
     *     contentId = Content identity shared by the reference.
     *     blobIndex = Catalog array index of the blob.
     */
    package void addFileReference(NamedBinaryBlob blob, FileSpec spec,
        JsonLocation location, ContentId contentId, size_t blobIndex)
    {
        if (auto existingIndex = location.relativePath in blobIndexByRelativePath)
        {
            const auto oldToken = fileRows[*existingIndex].contentId.adapterToken;
            if (oldToken != contentId.adapterToken)
                treeQueriesAvailable = false;
            return;
        }
        auto parent = parentPath(location.relativePath);
        addDirectory(parent);
        DirectoryId directoryId;
        if (parent.length > 0)
            directoryId = directoryRows[directoryIndexByPath[parent]].id;
        CatalogFile row;
        row.referenceId = ReferenceId(referenceToken(location.relativePath));
        row.contentId = contentId;
        row.directoryId = directoryId;
        row.locator = ContentLocator.file(location.physicalRelativePath);
        row.name = baseName(location.physicalRelativePath);
        row.relativePath = location.relativePath;
        row.size = cast(ulong) blob.fileSize;
        row.modifiedAt = spec.timeLastModified;
        row.availability = exists(buildPath(sourceRoot,
            location.physicalRelativePath))
            ? CatalogReferenceAvailability.available
            : CatalogReferenceAvailability.unavailable;
        row.hasFileType = blob.fileType.length > 0;
        row.hasMedia = hasAnyMediaStream(blob.mediaInfoSig);
        row.hasVideo = blob.mediaInfoSig !is null
            && anyStream(blob.mediaInfoSig.videoStreams);
        row.hasAudio = blob.mediaInfoSig !is null
            && anyStream(blob.mediaInfoSig.audioStreams);
        row.hasImage = blob.mediaInfoSig !is null
            && anyStream(blob.mediaInfoSig.imageStreams);
        row.hasText = blob.mediaInfoSig !is null
            && anyStream(blob.mediaInfoSig.textStreams);
        row.hasArchive = blob.archiveIndexKnown || blob.archiveSpecs !is null;
        row.hasTorrent = blob.torrentInfo !is null;
        fileRows ~= row;
        blobIndexByRelativePath[location.relativePath] = blobIndex;
        fileSpecByRelativePath[location.relativePath] = spec;
        if (parent.length > 0)
        {
            auto parentIndex = directoryIndexByPath[parent];
            directoryRows[parentIndex].fileCount++;
        }
        auto path = parent;
        while (path.length > 0)
        {
            auto index = directoryIndexByPath[path];
            directoryRows[index].aggregateSize += row.size;
            path = parentPath(path);
        }
    }
}
