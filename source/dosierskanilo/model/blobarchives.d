/** Archive member indexing for `NamedBinaryBlob` records.
 *
 * Shallow and deep archive scans, password requests, and resumable member
 * indexes are implemented here on top of `dosierarkivo`.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.model.blobarchives;

import std.algorithm;
import std.array;
import std.datetime.systime : SysTime;
import std.exception : assertThrown, enforce;
import std.string : startsWith;
import jsonizer;
import dosierarkivo;
import dosierarkivo.archive : appendArchiveVirtualPath,
    archivePathOccurrenceMarker, archivePathSeparator;
import dosierskanilo.archivebulk : ArchiveBulkMode, ArchiveBulkPlan,
    ArchiveBulkReservation, bulkExtractedMemberPath, maximumArchiveChunkBytes,
    maximumArchiveChunkMembers, minimumArchiveChunkBytes,
    planArchiveBulkExtraction, planArchiveChunk, sharedArchiveBulkStaging;
import dosierskanilo.catalogbackend : ArchiveEntryId, ContentId, ContentLocator,
    ReferenceId;
import dosierskanilo.logging;
import dosierskanilo.options;
import dosierskanilo.progress;
import dosierskanilo.membercontentcache : MemberContentCache,
    MemberContentCacheClosedException, MemberContentCacheException,
    MemberContentCancelledException, MemberContentLease,
    sharedMemberContentCache;
import dosierskanilo.metadata.digests;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.archivespec;
import dosierskanilo.model.checksums;
import dosierskanilo.model.filespec;
import dosierskanilo.model.namedbinaryblob;

/** Build the cache identity for one archive container.
 *
 * Params:
 *     blob = Blob describing the archive container.
 *     physicalPath = Path to the archive on disk.
 *     displayPath = Preferred stable display path when no digests are known.
 * Returns: A fingerprint-based key when complete digests exist, otherwise a
 *     path-and-size-based key.
 */
private string archiveCacheIdentity(NamedBinaryBlob blob,
	string physicalPath, string displayPath)
{
	import std.conv : to;

	if (blob.checkSums.hasDigests)
		return "fingerprint:" ~ blob.fileSize.to!string ~ ":"
			~ blob.checkSums.md5sum_b64 ~ ":" ~ blob.checkSums.sha1sum_b64
			~ ":" ~ blob.checkSums.xxh64sum_b64;
	return "path:" ~ (displayPath.length > 0 ? displayPath : physicalPath)
		~ "\0" ~ blob.fileSize.to!string ~ "\0" ~ blob.getFirstFileModDate;
}

/** Index archive members and optionally inspect them deeply.
 *
 * The blob must describe one archive file. Shallow indexing records member
 * names; deep indexing extracts each safe member through the leased member
 * cache to collect size, checksums, file type, and MediaInfo. Nested archives
 * are indexed recursively up to `maxDepth`.
 *
 * Params:
 *   obj = archive blob to update in place.
 *   rescan = force a fresh index even when archive metadata exists.
 *   deep = extract members for checksums and detailed metadata.
 *   gotCtrlC = optional cooperative cancellation flag.
 *   progressCallBack = optional progress callback.
 *   passwordCallback = optional callback for encrypted archives.
 *   depth = current nesting depth (zero for the outer archive).
 *   maxDepth = maximum nested archive depth.
 *   displayArchivePath = canonical virtual path of this container when nested.
 *   memberCache = shared member-content cache; a process default is used when null.
 *   inspectMemberFileType = run file-type detection on extracted members.
 *   inspectMemberMediaInfo = extract MediaInfo signatures for members.
 *   archiveBulkMode = bulk-extraction policy for deep scans.
 *   archiveChunkBytes = preferred uncompressed bytes per chunk; zero derives it
 *       from the staging limit.
 * Throws:
 *   `ArchivePasswordRequiredException`/`ArchivePasswordCancelledException` when
 *   a password is needed and cannot be supplied, or extraction errors that are
 *   not recoverable for a duplicate occurrence.
 */
void updateArchives(NamedBinaryBlob obj,
	bool rescan = false,
	bool deep = true,
	shared(bool)* gotCtrlC = null,
	ProgressCallBack* progressCallBack = null,
	ArchivePasswordCallback passwordCallback = null,
	size_t depth = 0,
	size_t maxDepth = 8,
	string displayArchivePath = "",
	MemberContentCache memberCache = null,
	bool inspectMemberFileType = false,
	bool inspectMemberMediaInfo = false,
	ArchiveBulkMode archiveBulkMode = ArchiveBulkMode.automatic,
	ulong archiveChunkBytes = 0)
{
	import std.conv : to;
	import core.atomic : atomicLoad;
	import std.file : getSize, getTimes;
	import std.string : format;

	if (memberCache is null)
		memberCache = sharedMemberContentCache();

	const bool resumePartial = !rescan && deep && obj.archiveIndexKnown
		&& !obj.archiveIndexDeep && obj.archiveScanCursor > 0;
	const bool needsArchiveScan = obj.archiveSpecs is null || rescan
		|| resumePartial
		|| (deep && obj.archiveIndexKnown && !obj.archiveIndexDeep);
	if (needsArchiveScan)
	{
		bool archiveFound;
		import std.algorithm.sorting : sort;
		import std.file : exists;

		/* Do not trust the stored size alone: imported catalogs may carry a
		 * zero size for a file that exists on disk. Only skip the work when
		 * there is neither a stored size nor an existing physical file. */
		auto existingFiles = obj.getExistingFiles;
		if (obj.fileSize || existingFiles.length > 0)
		{
			auto filespecs = obj.fileSpecs.sort;
			foreach (spec; existingFiles)
			{
				import std.string : startsWith;
				import std.algorithm.searching : canFind;

				if (obj.fileType.startsWith("RAR")
					&& obj.fileType.canFind("EncryptedBlockHeader"))
				{
					logLineVerbose();
					logFLineVerbose(
						"Found RAR archive with encrypted block header, skipping archive scan for file '%s'", spec
							.fileName);
					continue;
				}
				auto archiveObj = fileArchive(spec.fileName);
				if (archiveObj)
				{
					const auto archiveDisplayPath = displayArchivePath.length > 0
						? displayArchivePath : spec.fileName;
					const auto containerCacheKey = archiveCacheIdentity(obj,
						spec.fileName, archiveDisplayPath);
					const auto containerCacheIdentity = archiveCacheIdentity(obj,
						spec.fileName, archiveDisplayPath);
					logLineVerbose();
					logFLineVerbose("Found archive of type '%s'", archiveObj.fileType);
					logFLineVerbose("  with file '%s'", spec.fileName);
					logFLineVerbose("  with size %d", obj.fileSize);
					logFLineVerbose("  with 'file' type '%s'", obj.fileType);

					string password = obj.archivePassword;
                    ArchiveEntryDescriptor[] archiveEntries;
                    bool passwordPrompted;
                    size_t passwordAttempts;
                    while (true)
                    {
                        try
                        {
                            archiveEntries = archiveObj.getEntryDescriptors(password);
                            enforce(archiveEntries !is null,
                                "Archive handler returned no entry index for "
                                ~ spec.fileName);
                            break;
						}
						catch (ArchivePasswordRequiredException ex)
						{
							if (++passwordAttempts >= 3)
								throw new ArchivePasswordRequiredException(
									"Archive password rejected repeatedly for '"
									~ archiveDisplayPath ~ "'.");
							requestPassword(ex.msg, archiveDisplayPath,
								passwordCallback, password);
							passwordPrompted = true;
						}
					}
                    if (passwordPrompted)
                        obj.archivePassword = password;
                    logFLineVerbose("  with %d entries", archiveEntries.length);

                    const bool resuming = !rescan && deep
                        && obj.archiveIndexKnown && !obj.archiveIndexDeep
                        && obj.archiveScanCursor > 0;
                    const size_t startIndex = resuming
                        && obj.archiveScanCursor <= archiveEntries.length
                        ? obj.archiveScanCursor : 0;
                    obj.archiveScanResumed = startIndex > 0;
                    if (deep)
                        logFLineVerbose("  archive scan state: known=%s deep=%s cursor=%d start=%d",
                            obj.archiveIndexKnown, obj.archiveIndexDeep,
                            obj.archiveScanCursor, startIndex);

                    ArchiveBulkReservation bulkReservation;
                    ArchiveBulkReservation chunkReservation;
                    string stagedRoot;
                    string chunkRoot;
                    size_t chunkEndIndex;
                    bool bulkExtracted;
                    bool chunkingEnabled;
                    ulong chunkTargetBytes;
                    scope (exit)
                    {
                        if (chunkReservation !is null)
                            chunkReservation.release();
                        if (bulkReservation !is null)
                            bulkReservation.release();
                    }

                    void releaseChunk()
                    {
                        if (chunkReservation !is null)
                        {
                            chunkReservation.release();
                            chunkReservation = null;
                        }
                        chunkRoot = "";
                        chunkEndIndex = 0;
                        stagedRoot = "";
                    }

                    ArchiveSpec[] scannedSpecs;
                    if (startIndex > 0 && obj.archiveSpecs !is null)
                        foreach (existingSpec; obj.archiveSpecs)
                            if (existingSpec !is null
                                && existingSpec.entryIndex < startIndex)
                                scannedSpecs ~= existingSpec;

                    void cancelAt(size_t nextIndex)
                    {
                        const size_t completed = nextIndex > 0 ? nextIndex
                            : (resuming ? startIndex : 0);
                        if (completed > 0)
                        {
                            obj.archiveScanCursor = completed;
                            obj.archiveIndexKnown = true;
                            obj.archiveIndexDeep = false;
                            obj.archiveSpecs = scannedSpecs;
                            obj.archiveScanResumed = startIndex > 0;
                        }
                        throw new ArchiveScanCancelledException(
                            "Archive scan was cancelled; "
                            ~ completed.to!string ~ " entries completed.");
                    }

                    ArchiveBulkPlan bulkPlan;
                    if (deep)
                        bulkPlan = planArchiveBulkExtraction(archiveEntries,
                            archiveBulkMode, archiveObj.fileType);
                    bool wholeBulkBudgetBlocked;
                    const bool chunkPreferred = archiveChunkBytes > 0
                        && bulkPlan.requiredBytes > archiveChunkBytes;
                    if (deep && startIndex == 0 && bulkPlan.useBulk
                        && !chunkPreferred)
                    {
                        string bulkFailure;
                        try
                        {
                            bulkReservation = sharedArchiveBulkStaging()
                                .reserve(bulkPlan.requiredBytes);
                            if (bulkReservation is null)
                            {
                                wholeBulkBudgetBlocked = true;
                                bulkFailure =
                                    "staging budget or free space unavailable";
                            }
                            else
                            {
                                if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                    cancelAt(startIndex);
                                if (!archiveObj.extractAllTo(
                                        bulkReservation.path, password,
                                        gotCtrlC))
                                    bulkFailure =
                                        "archive adapter does not support bulk extraction";
                                else
                                {
                                    bulkExtracted = true;
                                    stagedRoot = bulkReservation.path;
                                    logFLineVerbose(
                                        "  bulk extracted %d entries into '%s'",
                                        archiveEntries.length,
                                        bulkReservation.path);
                                }
                            }
                        }
                        catch (ArchivePasswordRequiredException ex)
                        {
                            bulkFailure = oneLineFailure(ex.msg);
                        }
                        catch (ArchiveScanCancelledException ex)
                        {
                            throw ex;
                        }
                        catch (Exception ex)
                        {
                            if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                cancelAt(startIndex);
                            bulkFailure = oneLineFailure(ex.msg);
                        }
                        if (bulkFailure.length > 0 && !bulkExtracted)
                        {
                            if (bulkReservation !is null)
                            {
                                bulkReservation.release();
                                bulkReservation = null;
                            }
                            logFLineVerbose(
                                "  bulk extraction skipped: %s; using per-member extraction.",
                                bulkFailure);
                        }
                    }
                    else if (deep && !bulkPlan.useBulk)
                        logFLineVerbose("  bulk extraction not selected: %s",
                            bulkPlan.reason);

                    if (deep && !bulkExtracted && bulkPlan.useBulk
                        && (startIndex > 0 || wholeBulkBudgetBlocked
                            || chunkPreferred))
                    {
                        chunkingEnabled = true;
                        const auto staging = sharedArchiveBulkStaging();
                        chunkTargetBytes = archiveChunkBytes > 0
                            ? archiveChunkBytes : staging.byteLimit / 4;
                        if (archiveChunkBytes == 0)
                        {
                            if (chunkTargetBytes < minimumArchiveChunkBytes)
                                chunkTargetBytes = minimumArchiveChunkBytes;
                            if (chunkTargetBytes > maximumArchiveChunkBytes)
                                chunkTargetBytes = maximumArchiveChunkBytes;
                        }
                        if (chunkTargetBytes > staging.byteLimit / 2)
                            chunkTargetBytes = staging.byteLimit / 2;
                        logFLineVerbose(
                            "  using chunked extraction with a %d byte target",
                            chunkTargetBytes);
                    }

                    size_t membersWithoutFingerprint;
                    if (progressCallBack !is null)
                        progressCallBack.report(startIndex,
                            archiveEntries.length);

                    foreach (idx, descriptor; archiveEntries)
                    {
                        if (idx < startIndex)
                            continue;
                        if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                            cancelAt(idx);
                        if (chunkingEnabled && idx >= chunkEndIndex)
                        {
                            releaseChunk();
                            auto chunk = planArchiveChunk(archiveEntries,
                                idx, chunkTargetBytes,
                                maximumArchiveChunkMembers);
                            if (chunk.eligible)
                            {
                                string chunkFailure;
                                ArchiveBulkReservation reservation;
                                try
                                {
                                    reservation = sharedArchiveBulkStaging()
                                        .reserve(chunk.requiredBytes);
                                    if (reservation is null)
                                        chunkFailure =
                                            "staging budget unavailable";
                                    else
                                    {
                                        if (gotCtrlC !is null
                                            && atomicLoad(*gotCtrlC))
                                        {
                                            reservation.release();
                                            reservation = null;
                                            cancelAt(idx);
                                        }
                                        if (!archiveObj.extractEntriesTo(
                                                chunk.names, reservation.path,
                                                password, gotCtrlC))
                                            chunkFailure =
                                                "adapter does not support chunk extraction";
                                        else
                                        {
                                            chunkReservation = reservation;
                                            reservation = null;
                                            chunkRoot =
                                                chunkReservation.path;
                                            stagedRoot = chunkRoot;
                                            chunkEndIndex = chunk.endIndex;
                                            logFLineVerbose(
                                                "  chunk-extracted %d named members into '%s'",
                                                chunk.names.length, chunkRoot);
                                        }
                                    }
                                }
                                catch (ArchivePasswordRequiredException ex)
                                {
                                    chunkFailure = oneLineFailure(ex.msg);
                                }
                                catch (ArchiveScanCancelledException ex)
                                {
                                    if (reservation !is null)
                                    {
                                        reservation.release();
                                        reservation = null;
                                    }
                                    throw ex;
                                }
                                catch (Exception ex)
                                {
                                    if (reservation !is null)
                                    {
                                        reservation.release();
                                        reservation = null;
                                    }
                                    if (gotCtrlC !is null
                                        && atomicLoad(*gotCtrlC))
                                        cancelAt(idx);
                                    chunkFailure = oneLineFailure(ex.msg);
                                }
                                if (reservation !is null)
                                {
                                    reservation.release();
                                    reservation = null;
                                }
                                if (chunkFailure.length > 0)
                                {
                                    logFLineVerbose(
                                        "  chunk extraction skipped: %s; using per-member extraction.",
                                        chunkFailure);
                                    chunkingEnabled = false;
                                    chunkEndIndex = idx;
                                }
                            }
                            else
                                chunkEndIndex = idx + 1;
                        }
                        const auto arcfile = descriptor.name;
                        logFLineVerbose("  with archive file '%s'", arcfile);

                        size_t arcFileSize;
                        string arcModTimeStr;
                        string extractedPath;
                        string memberFileType;
                        MediaInfoSig memberMediaInfo;
                        MemberContentLease extractionLease;
                        scope (exit)
                            if (extractionLease !is null)
                                extractionLease.release();
                        CheckSums sums = CheckSums();
                        if (descriptor.hasDuplicateName
                            && !archiveObj.supportsEntryOccurrence)
                            logFLineVerbose("Archive adapter cannot select duplicate occurrence %d of '%s'; leaving it without a deep fingerprint.",
                                descriptor.occurrence, descriptor.relativePath);
                        /* Directory entries are structure, not content. The
                         * browse tree synthesizes directories from member
                         * paths, so indexing an explicit directory as a
                         * member would create a duplicate, non-expandable
                         * node (and surface empty directories that the tree
                         * must not show). */
                        if (descriptor.isDirectory)
                        {
                            if (progressCallBack !is null)
                                progressCallBack.report(idx + 1,
                                    archiveEntries.length);
                            continue;
                        }
                        if (!descriptor.hasSafePath
                            || (descriptor.hasDuplicateName
                                && !archiveObj.supportsEntryOccurrence))
                        {
                            auto unscannedEntry = new ArchiveSpec(arcfile,
                                descriptor.hasSize ? descriptor.size : arcFileSize,
                                descriptor.hasModifiedAt
                                    ? descriptor.modifiedAt : arcModTimeStr,
                                sums);
                            unscannedEntry.entryIndex = idx;
                            unscannedEntry.occurrence = descriptor.occurrence;
                            unscannedEntry.hasIndexIdentity = true;
                            scannedSpecs ~= unscannedEntry;
                            if (progressCallBack !is null)
                                progressCallBack.report(idx + 1, archiveEntries.length);
                            continue;
                        }

                        if (deep)
                        {
                            if (stagedRoot.length > 0)
                                extractedPath = bulkExtractedMemberPath(
                                    stagedRoot, descriptor);
                            if (extractedPath.length == 0)
                            {
                                bool exOk;
                                bool extractionPasswordPrompted;
                                string extractionFailure;
                                size_t extractionPasswordAttempts;
                                while (true)
                                {
                                    try
                                    {
                                        const auto occurrence = descriptor.occurrence
                                            .to!string;
                                        const auto fallbackIdentity = containerCacheKey
                                            ~ archivePathSeparator() ~ descriptor.relativePath
                                            ~ archivePathOccurrenceMarker() ~ occurrence;
                                        const auto cacheContainer = ReferenceId(
                                            "scanner-container:" ~ containerCacheKey);
                                        const auto cacheEntry = ArchiveEntryId(
                                            "scanner-entry:" ~ descriptor.relativePath
                                            ~ ":" ~ occurrence);
                                        const auto locator = ContentLocator.entry(
                                            cacheContainer, cacheEntry);
                                        extractionLease = memberCache.acquire(locator,
                                            ContentId.init, fallbackIdentity,
                                            descriptor.relativePath,
                                            descriptor.hasSize ? descriptor.size : 0,
                                            (string destinationDirectory) {
                                                if (gotCtrlC !is null
                                                    && atomicLoad(*gotCtrlC))
                                                    return false;
                                                return archiveObj.extractEntry(descriptor,
                                                    destinationDirectory, password,
                                                    gotCtrlC);
                                            }, gotCtrlC);
                                        exOk = extractionLease !is null;
                                        extractedPath = extractionLease.path;
                                        break;
                                    }
                                    catch (ArchivePasswordRequiredException ex)
                                    {
                                        if (++extractionPasswordAttempts >= 3)
                                            throw new ArchivePasswordRequiredException(
                                                "Archive password rejected repeatedly for '"
                                                ~ archiveDisplayPath ~ "'.");
                                        requestPassword(ex.msg, archiveDisplayPath,
                                            passwordCallback, password);
                                        extractionPasswordPrompted = true;
                                    }
                                    catch (MemberContentCancelledException failure)
                                    {
                                        cancelAt(idx);
                                    }
                                    catch (MemberContentCacheClosedException failure)
                                    {
                                        throw failure;
                                    }
                                    catch (MemberContentCacheException failure)
                                    {
                                        if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                            cancelAt(idx);
                                        extractionFailure = oneLineFailure(failure.msg);
                                        break;
                                    }
                                    catch (Exception failure)
                                    {
                                        /* A damaged or unsupported member must not
                                         * discard the complete archive index. Keep
                                         * the entry metadata and let preview fail
                                         * for that member only. */
                                        if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                            cancelAt(idx);
                                        extractionFailure = oneLineFailure(failure.msg);
                                        break;
                                    }
                                }
                                if (extractionPasswordPrompted)
                                    obj.archivePassword = password;
                                if (extractionFailure.length == 0 && !exOk)
                                    extractionFailure = "Archive adapter produced no file.";
                                if (extractionFailure.length > 0)
                                {
                                    ++membersWithoutFingerprint;
                                    logFLineVerbose("Could not extract archive member '%s' from '%s': %s; storing index metadata only.",
                                        arcfile, archiveDisplayPath, extractionFailure);
                                    auto unscannedEntry = new ArchiveSpec(arcfile,
                                        descriptor.hasSize
                                            ? descriptor.size : arcFileSize,
                                        descriptor.hasModifiedAt
                                            ? descriptor.modifiedAt : arcModTimeStr,
                                        sums);
                                    unscannedEntry.entryIndex = idx;
                                    unscannedEntry.occurrence = descriptor.occurrence;
                                    unscannedEntry.hasIndexIdentity = true;
                                    scannedSpecs ~= unscannedEntry;
                                    if (progressCallBack !is null)
                                        progressCallBack.report(idx + 1,
                                            archiveEntries.length);
                                    continue;
                                }

                            }

                            import dosierskanilo.metadata.digests;
                            ubyte[] md5sum_s, sha1sum_s, xxh64sum_s;
                            /* The archive progress channel counts entries, not
                             * bytes. Do not feed member digest byte progress
                             * into it or concurrent workers display changing
                             * byte totals under an "entries" label. */
                            calculatesDigests(gotCtrlC, extractedPath,
                                &md5sum_s, &sha1sum_s, &xxh64sum_s, null);
                            if (gotCtrlC !is null && atomicLoad(*gotCtrlC))
                                cancelAt(idx);
                            if (progressCallBack !is null)
                                progressCallBack.report(idx, archiveEntries.length);

                            sums.set_md5sum = md5sum_s;
                            sums.set_sha1sum = sha1sum_s;
                            sums.set_xxh64 = xxh64sum_s;

                            SysTime arcAccessTime;
                            SysTime arcModTime;
                            extractedPath.getTimes(arcAccessTime, arcModTime);
                            arcModTimeStr = arcModTime.toISOExtString;
                            arcFileSize = extractedPath.getSize;
                            auto extractedBlob = new NamedBinaryBlob(
                                [new FileSpec(extractedPath, arcModTimeStr)],
                                arcFileSize);
                            extractedBlob.checkSums = sums;
                            if (inspectMemberFileType)
                                try
                                    updateFileType(extractedBlob, true);
                                catch (Exception failure)
                                    logFLineVerbose("Could not detect file type for archive member '%s': %s",
                                        arcfile, failure.msg);
                            if (inspectMemberMediaInfo)
                                try
                                    updateMediaInfo(extractedBlob, true);
                                catch (Exception failure)
                                    logFLineVerbose("Could not extract MediaInfo for archive member '%s': %s",
                                        arcfile, failure.msg);
                            memberFileType = extractedBlob.fileType;
                            memberMediaInfo = extractedBlob.mediaInfoSig;
                        }
                        ArchiveSpec[] nestedEntries;
                        string nestedPassword;
                        if (deep && depth < maxDepth && extractedPath.length > 0)
                        {
                            auto nestedArchive = fileArchive(extractedPath);
                            if (nestedArchive !is null)
                            {
                                auto nestedBlob = new NamedBinaryBlob();
                                nestedBlob.fileSize = arcFileSize;
                                nestedBlob.checkSums = sums;
                                nestedBlob.fileSpecs = [new FileSpec(extractedPath,
                                    arcModTimeStr)];
                                const auto nestedDisplayPath = appendArchiveVirtualPath(
                                    archiveDisplayPath, descriptor.relativePath,
                                    descriptor.occurrence > 0
                                        ? descriptor.occurrence : size_t.max);
                                try
                                    updateArchives(nestedBlob, true, deep,
                                        gotCtrlC, progressCallBack,
                                        passwordCallback, depth + 1, maxDepth,
                                        nestedDisplayPath, memberCache,
                                        inspectMemberFileType,
                                        inspectMemberMediaInfo, archiveBulkMode,
                                        archiveChunkBytes);
                                catch (ArchiveScanCancelledException)
                                    cancelAt(idx);
                                nestedEntries = nestedBlob.archiveSpecs;
                                nestedPassword = nestedBlob.archivePassword;
                            }
                        }
                        auto aspec = new ArchiveSpec(arcfile,
                            arcFileSize != 0 ? arcFileSize
                                : descriptor.hasSize ? descriptor.size : 0,
                            arcModTimeStr.length > 0 ? arcModTimeStr
                                : descriptor.hasModifiedAt
                                    ? descriptor.modifiedAt : "",
                            sums);
                        aspec.entryIndex = idx;
                        aspec.occurrence = descriptor.occurrence;
                        aspec.hasIndexIdentity = true;
                        aspec.nestedEntries = nestedEntries;
                        aspec.archivePassword = nestedPassword;
                        aspec.fileType = memberFileType;
                        if (memberMediaInfo !is null)
                            aspec.mediaInfoSig = memberMediaInfo.dup;
                        scannedSpecs ~= aspec;

                        if (progressCallBack !is null)
                            progressCallBack.report(idx + 1, archiveEntries.length);
                        if (chunkReservation !is null
                            && idx + 1 >= chunkEndIndex)
                            releaseChunk();
					}
                    if (membersWithoutFingerprint > 0)
                        logFLineVerbose("Archive '%s': stored %d member(s) without deep fingerprints after extraction failures.",
                            archiveDisplayPath, membersWithoutFingerprint);
                    obj.archiveSpecs = scannedSpecs;
                    obj.archiveScanCursor = 0;
                    obj.archiveScanResumed = startIndex > 0;
                    obj.archiveIndexKnown = true;
                    obj.archiveIndexDeep = deep;
                    archiveFound = true;
					break;
				}
			}
		}
		else if (obj.fileSpecs.length > 0)
			logFLineVerbose("No existing file for archive scan (stored size %d, %d candidate(s)).",
				obj.fileSize, obj.fileSpecs.length);
		if (rescan && !archiveFound)
		{
			obj.archiveSpecs = null;
			obj.archiveScanCursor = 0;
			obj.archiveScanResumed = false;
		}
	}
}

/** Collapse multi-line archive tool output to its most useful line.
 *
 * Params:
 *     message = Raw tool error text.
 * Returns: The last non-empty trimmed line, or `"archive tool failed"` when no
 *     non-empty line exists.
 */
private string oneLineFailure(string message)
{
	import std.string : splitLines, strip;

	string result = "archive tool failed";
	foreach (line; message.splitLines)
	{
		const trimmed = line.strip;
		if (trimmed.length > 0)
			result = trimmed;
	}
	return result;
}

/** Ask the callback for an archive password and store it.
 *
 * Params:
 *     reason = Why the password is required, passed to the callback.
 *     archivePath = Archive path passed to the callback.
 *     callback = Password callback; must not be `null`.
 *     password = Receives the supplied password on success.
 * Throws: `ArchivePasswordRequiredException` when no callback is available, or
 *     `ArchivePasswordCancelledException` when the callback declines.
 */
private void requestPassword(string reason, string archivePath,
	ArchivePasswordCallback callback, ref string password)
{
	if (callback is null)
		throw new ArchivePasswordRequiredException(
			"Archive password is required for '" ~ archivePath ~ "': " ~ reason);
	string suppliedPassword;
	if (!callback(archivePath, reason, suppliedPassword))
		throw new ArchivePasswordCancelledException(
			"Archive password request was cancelled for '" ~ archivePath ~ "'.");
	password = suppliedPassword;
}

@("updateArchives")
unittest
{
	import std.stdio;
	import std.file; // : exists, remove, write, mkdirRecurse, rmdirRecurse;
	import std.process;
	import std.conv : to;
	import std.string : format;
	import std.path : buildPath;
	import dosierskanilo.testdata : ensureSyntheticTestCatalog;

	auto fixture = ensureSyntheticTestCatalog();
	string filename = buildPath(fixture.catalogRoot, "media", "tone.wav");
	auto fh = File(filename);
	auto dco = new NamedBinaryBlob(filename, fh.size, SysTime(4_237_892));
	updateArchives(dco, true);
	assert(dco.archiveSpecs.length == 0);

	enum string fnMany = "updateTest-many.zip";
	enum string stagingDir = ".test/updateArchives-many-entries";

	/* Delete the archive with many entries, and the staging directory, if they exist.
	*/
	void deleteManyEntriesArchive()
	{
		if (fnMany.exists)
			std.file.remove(fnMany);
		if (stagingDir.exists)
			rmdirRecurse(stagingDir);
	}

	/* Create an archive with more than 10 entries, to test the code path for that.
	 * The code should scan all entries, not just the first 10.
	 */
	void createManyEntriesArchive(size_t entryCount)
	{
		deleteManyEntriesArchive();
		mkdirRecurse(stagingDir);

		foreach (idx; 0 .. entryCount)
		{
			auto fileName = buildPath(stagingDir, format("entry-%02d.txt", idx));
			std.file.write(fileName, "archive entry " ~ idx.to!string);
		}

		auto rc = executeShell("zip -q \"%s\" %s/*".format(fnMany, stagingDir));
		write(rc.output);
		assert(rc.status == 0, rc.output);
	}

	auto archivePath = buildPath(fixture.catalogRoot, "archives", "sample.zip");
	auto fh1 = File(archivePath);
	auto dco1 = new NamedBinaryBlob(archivePath, fh1.size, SysTime(4_237_892));
	updateArchives(dco1, true);
	assert(dco1.archiveSpecs.length > 0);
	assert(dco1.archiveSpecs.length == 7);
	foreach (entry; dco1.archiveSpecs)
		assert(entry.checkSums.hasDigests,
			"deep archive scans calculate each generated entry checksum");
	auto firstScanEntries = dco1.archiveSpecs.length;
	updateArchives(dco1, true);
	assert(dco1.archiveSpecs.length == firstScanEntries,
		"rescan replaces the entry index instead of appending duplicates");

	createManyEntriesArchive(11);
	scope (success)
		deleteManyEntriesArchive();

	auto fh2 = File(fnMany);
	auto dco2 = new NamedBinaryBlob(fnMany, fh2.size, SysTime(4_237_892));
	updateArchives(dco2, true);
	assert(dco2.archiveSpecs.length >= 11,
		"Expected all archive entries to be scanned for archives with more than 10 files.\nGot %d entries.".format(
			dco2.archiveSpecs.length));
}

@("updateArchives requests and retains encrypted ZIP passwords")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : execute, Config;
	import std.uuid : randomUUID;
	import dosierarkivo.archive : ArchivePasswordCallback;
	import dosierskanilo.membercontentcache : MemberContentCache;

	auto root = buildPath(tempDir(), "dosierskanilo-encrypted-archive-"
		~ randomUUID().toString());
	mkdirRecurse(root);
	scope (exit)
	{
		if (exists(root))
			rmdirRecurse(root);
	}

	write(buildPath(root, "payload.txt"), "encrypted archive payload\n");
	auto archivePath = buildPath(root, "private.zip");
	auto create = execute(["zip", "-q", "-P", "archive-secret", "private.zip",
		"payload.txt"], null, Config.none, size_t.max, root);
	assert(create.status == 0, create.output);

	auto blob = new NamedBinaryBlob(archivePath, archivePath.getSize,
		SysTime(1_234_567));
	size_t prompts;
	ArchivePasswordCallback callback = (string requestedPath, string reason,
		out string password) {
		assert(requestedPath == archivePath);
		assert(reason.length > 0);
		++prompts;
		password = "archive-secret";
		return true;
	};
	auto successfulCache = new MemberContentCache(buildPath(root, "cache-success"));
	updateArchives(blob, true, true, null, null, callback, 0, 8, "",
		successfulCache);
	successfulCache.close();
	assert(prompts == 1);
	assert(blob.archivePassword == "archive-secret");
	assert(blob.archiveSpecs.length == 1);
	assert(blob.archiveSpecs[0].fileName == "payload.txt");

	import std.exception : assertThrown;
	auto rejectedBlob = new NamedBinaryBlob(archivePath, archivePath.getSize,
		SysTime(1_234_567));
	size_t rejectedPrompts;
	ArchivePasswordCallback rejectWrongPassword = (string requestedPath,
		string reason, out string password) {
		++rejectedPrompts;
		if (rejectedPrompts == 1)
		{
			password = "wrong-password";
			return true;
		}
		return false;
	};
	auto rejectedCache = new MemberContentCache(buildPath(root, "cache-rejected"));
	assertThrown!ArchivePasswordCancelledException(updateArchives(rejectedBlob,
		true, true, null, null, rejectWrongPassword, 0, 8, "", rejectedCache));
	rejectedCache.close();
	assert(rejectedPrompts == 2);
	assert(rejectedBlob.archivePassword.length == 0,
		"a cancelled wrong-password attempt must not be persisted");
}

@("damaged archive member keeps the rest of the index")
unittest
{
	import std.algorithm.searching : countUntil;
	import std.file : exists, getSize, mkdirRecurse, read, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute, executeShell;
	import std.uuid : randomUUID;

	if (executeShell("command -v rar").status != 0
		|| executeShell("command -v unrar").status != 0)
		return;

	auto root = buildPath(tempDir(), "dosierskanilo-damaged-member-"
		~ randomUUID().toString());
	mkdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	enum string goodPayload = "GOODMEMBER-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
	enum string brokenPayload = "BROKENMEMBER-BBBBBBBBBBBBBBBBBBBBBBBBBBBB";
	write(buildPath(root, "good.txt"), goodPayload);
	write(buildPath(root, "broken.txt"), brokenPayload);
	auto archivePath = buildPath(root, "bundle.rar");
	auto create = execute(["rar", "a", "-m0", "-idq", archivePath,
		"good.txt", "broken.txt"], null, Config.none, size_t.max, root);
	assert(create.status == 0, create.output);

	/* Stored RAR members keep their bytes verbatim, so flipping one byte in
	 * the archive makes `unrar` report a checksum error for that member. */
	auto data = cast(ubyte[]) read(archivePath);
	const offset = data.countUntil(cast(const(ubyte)[]) brokenPayload);
	assert(offset >= 0);
	data[offset + 3] ^= 0xFF;
	write(archivePath, data);

	auto blob = new NamedBinaryBlob(archivePath, getSize(archivePath),
		SysTime(1_234_567));
	auto cache = new MemberContentCache(buildPath(root, "cache"));
	scope (exit)
		cache.close();
	updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);

	assert(blob.archiveSpecs.length == 2);
	bool sawGood;
	bool sawBroken;
	foreach (spec; blob.archiveSpecs)
	{
		if (spec.fileName == "good.txt")
		{
			sawGood = true;
			assert(spec.checkSums.hasDigests);
		}
		else if (spec.fileName == "broken.txt")
		{
			sawBroken = true;
			assert(!spec.checkSums.hasDigests,
				"a damaged member must keep index metadata without digests");
			assert(spec.fileSize == brokenPayload.length);
		}
	}
	assert(sawGood);
	assert(sawBroken);
}

@("RAR directory entries are not stored as archive members")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute, executeShell;
	import std.uuid : randomUUID;

	if (executeShell("command -v rar").status != 0)
		return;

	auto root = buildPath(tempDir(), "dosierskanilo-rar-directories-"
		~ randomUUID().toString());
	mkdirRecurse(buildPath(root, "input", "001", "empty", "deeper"));
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	write(buildPath(root, "input", "001", "a.txt"), "a");
	auto archivePath = buildPath(root, "bundle.rar");
	auto create = execute(["rar", "a", "-r", "-idq", archivePath, "001"],
		null, Config.none, size_t.max, buildPath(root, "input"));
	assert(create.status == 0, create.output);

	auto blob = new NamedBinaryBlob(archivePath, getSize(archivePath),
		SysTime(1_234_567));
	auto cache = new MemberContentCache(buildPath(root, "cache"));
	scope (exit)
		cache.close();
	updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);

	assert(blob.archiveSpecs.length == 1);
	assert(blob.archiveSpecs[0].fileName == "001/a.txt");
}

@("archive scanning ignores a stale zero file size")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : Config, execute;
	import std.uuid : randomUUID;

	auto root = buildPath(tempDir(), "dosierskanilo-zero-size-archive-"
		~ randomUUID().toString());
	mkdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	write(buildPath(root, "payload.txt"), "payload");
	auto archivePath = buildPath(root, "payload.zip");
	auto create = execute(["zip", "-q", "-j", archivePath,
		buildPath(root, "payload.txt")]);
	assert(create.status == 0, create.output);

	/* JSON imports may leave a zero size on a reference whose file exists. */
	auto blob = new NamedBinaryBlob(archivePath, 0, SysTime(1_234_567));
	assert(blob.fileSize == 0);
	auto cache = new MemberContentCache(buildPath(root, "cache"));
	scope (exit)
		cache.close();
	updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);

	assert(blob.archiveSpecs.length == 1);
	assert(blob.archiveSpecs[0].fileName == "payload.txt");
}

@("failed nested archive scan preserves the previous index")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "archive-partial-index-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "good.txt"), "payload");
    write(buildPath(root, "inner.tar"), "not a tar archive");
    const archivePath = buildPath(root, "outer.tar");
    auto created = execute(["tar", "-cf", archivePath, "-C", root,
        "good.txt", "inner.tar"]);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto previous = new ArchiveSpec("previous.txt", 1, "", CheckSums());
    blob.archiveSpecs = [previous];
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    bool failed;
    try
        updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);
    catch (Exception)
        failed = true;
    assert(failed, "the corrupt nested archive must fail the scan");
    assert(blob.archiveSpecs.length == 1);
    assert(blob.archiveSpecs[0] is previous,
        "a failed scan must keep the previous complete index");
}

@("shallow archive scan stores member size and timestamp")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "shallow-member-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    const payload = buildPath(root, "member.txt");
    write(payload, "shallow-payload");
    const archivePath = buildPath(root, "shallow.zip");
    auto created = execute(["zip", "-q", "-j", archivePath, payload]);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    updateArchives(blob, true, false, null, null, null, 0, 8, "", cache);
    assert(blob.archiveSpecs.length == 1);
    assert(blob.archiveSpecs[0].fileSize == getSize(payload));
    assert(blob.archiveSpecs[0].timeLastModified.length >= 16,
        blob.archiveSpecs[0].timeLastModified);
    assert(!blob.archiveSpecs[0].checkSums.hasDigests,
        "a shallow scan must not fabricate checksums");
}

@("deep archive scan can use bulk extraction instead of the member cache")
unittest
{
    import std.file : DirEntry, SpanMode, dirEntries, exists, getSize,
        isFile, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;
    import dosierskanilo.archivebulk : ArchiveBulkMode;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "archive-bulk-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "first.txt"), "first payload");
    write(buildPath(root, "second.txt"), "second payload");
    const archivePath = buildPath(root, "bulk.zip");
    auto created = execute(["zip", "-q", "-j", archivePath,
        buildPath(root, "first.txt"), buildPath(root, "second.txt")]);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    updateArchives(blob, true, true, null, null, null, 0, 8, "", cache,
        false, false, ArchiveBulkMode.always);
    assert(blob.archiveSpecs.length == 2);
    foreach (entry; blob.archiveSpecs)
        assert(entry.checkSums.hasDigests,
            "bulk-extracted members must receive checksums");

    size_t cachedFiles;
    if (exists(cache.rootPath))
        foreach (DirEntry entry; dirEntries(cache.rootPath, SpanMode.depth))
            if (isFile(entry.name))
                ++cachedFiles;
    assert(cachedFiles == 0,
        "bulk extraction must not populate the per-member cache");

    auto perMemberBlob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    updateArchives(perMemberBlob, true, true, null, null, null, 0, 8, "",
        cache, false, false, ArchiveBulkMode.never);
    assert(perMemberBlob.archiveSpecs.length == 2);
    foreach (entry; perMemberBlob.archiveSpecs)
        assert(entry.checkSums.hasDigests,
            "the per-member fallback must still calculate checksums");
    size_t fallbackFiles;
    if (exists(cache.rootPath))
        foreach (DirEntry entry; dirEntries(cache.rootPath, SpanMode.depth))
            if (isFile(entry.name))
                ++fallbackFiles;
    assert(fallbackFiles == 2,
        "the never policy must use the per-member cache");
}

@("bulk deep scan stops promptly when cancellation is requested")
unittest
{
    import core.atomic : atomicStore;
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;
    import dosierskanilo.archivebulk : ArchiveBulkMode;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "archive-bulk-cancel-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    string[] members;
    foreach (index; 0 .. 8)
    {
        const name = "member-" ~ index.to!string ~ ".txt";
        write(buildPath(root, name), "payload-" ~ index.to!string);
        members ~= name;
    }
    const archivePath = buildPath(root, "cancel.zip");
    auto created = execute(["zip", "-q", "-j", archivePath]
        ~ members.map!(name => buildPath(root, name)).array);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    shared bool cancelled;
    ProgressCallBack progress;
    progress.contextual = (size_t completed, size_t total) {
        if (completed > 0)
            atomicStore(cancelled, true);
    };
    assertThrown!(Exception)(updateArchives(blob, true, true, &cancelled,
        &progress, null, 0, 8, "", cache, false, false,
        ArchiveBulkMode.always));
    assert(blob.archiveScanCursor > 0,
        "a cancelled scan must remember where to resume");
    assert(blob.archiveSpecs !is null,
        "completed members must remain available as a partial index");
    assert(blob.archiveIndexKnown && !blob.archiveIndexDeep,
        "a partial index is known but not deeply complete");
    size_t completed;
    foreach (entry; blob.archiveSpecs)
        if (entry !is null && entry.checkSums.hasDigests)
            ++completed;
    assert(completed > 0 && completed < 8,
        "only the members completed before cancellation belong to the partial index");
}

@("deep archive scan chunks large member sets")
unittest
{
    import std.conv : to;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getSize,
        isFile, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;
    import dosierskanilo.archivebulk : ArchiveBulkMode;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "archive-chunk-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    string[] memberPaths;
    foreach (index; 0 .. 8)
    {
        const memberPath = buildPath(root,
            "member-" ~ index.to!string ~ ".bin");
        write(memberPath, new char[1024]);
        memberPaths ~= memberPath;
    }
    const archivePath = buildPath(root, "chunks.zip");
    auto created = execute(["zip", "-q", "-j", archivePath] ~ memberPaths);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    updateArchives(blob, true, true, null, null, null, 0, 8, "", cache,
        false, false, ArchiveBulkMode.always, 2048);
    assert(blob.archiveSpecs.length == 8);
    foreach (entry; blob.archiveSpecs)
        assert(entry.checkSums.hasDigests,
            "chunk-extracted members must receive checksums");

    size_t cachedFiles;
    if (exists(cache.rootPath))
        foreach (DirEntry entry; dirEntries(cache.rootPath, SpanMode.depth))
            if (isFile(entry.name))
                ++cachedFiles;
    assert(cachedFiles == 0,
        "chunk extraction must not populate the per-member cache");
}

@("chunked archive scans resume after cancellation")
unittest
{
    import core.atomic : atomicStore;
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute, executeShell;
    import std.uuid : randomUUID;
    import dosierskanilo.archivebulk : ArchiveBulkMode;

    if (executeShell("command -v zip").status != 0)
        return;
    const root = buildPath(tempDir(), "archive-chunk-resume-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    string[] memberPaths;
    foreach (index; 0 .. 8)
    {
        const memberPath = buildPath(root,
            "member-" ~ index.to!string ~ ".bin");
        write(memberPath, new char[1024]);
        memberPaths ~= memberPath;
    }
    const archivePath = buildPath(root, "chunks.zip");
    auto created = execute(["zip", "-q", "-j", archivePath] ~ memberPaths);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    shared bool cancelled;
    ProgressCallBack progress;
    progress.contextual = (size_t completed, size_t total) {
        if (completed >= 3)
            atomicStore(cancelled, true);
    };
    assertThrown!Exception(updateArchives(blob, true, true, &cancelled,
        &progress, null, 0, 8, "", cache, false, false,
        ArchiveBulkMode.always, 2048));
    assert(blob.archiveScanCursor > 0);
    assert(blob.archiveIndexKnown && !blob.archiveIndexDeep);
    assert(blob.archiveSpecs !is null);
    const partial = blob.archiveSpecs.length;
    assert(partial > 0 && partial < 8, partial.to!string);

    updateArchives(blob, false, true, null, null, null, 0, 8, "", cache,
        false, false, ArchiveBulkMode.always, 2048);
    assert(blob.archiveScanCursor == 0);
    assert(blob.archiveIndexKnown && blob.archiveIndexDeep);
    assert(blob.archiveSpecs.length == 8,
        blob.archiveSpecs.length.to!string);
    foreach (entry; blob.archiveSpecs)
        assert(entry.checkSums.hasDigests);
}

@("archive progress reports entry counts, not member byte counts")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "archive-progress-units-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "small.txt"), "x");
    write(buildPath(root, "large.txt"), new char[4096]);
    const archivePath = buildPath(root, "progress.zip");
    auto created = execute(["zip", "-q", "-j", archivePath,
        buildPath(root, "small.txt"), buildPath(root, "large.txt")]);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    size_t[] maxima;
    ProgressCallBack progress;
    progress.contextual = (size_t completed, size_t total) {
        maxima ~= total;
    };
    updateArchives(blob, true, true, null, &progress, null, 0, 8, "", cache);
    assert(maxima.length > 0);
    foreach (maximum; maxima)
        assert(maximum == 2,
            "archive progress must stay in entry units");
}

@("deep archive scan rejects symbolic link members")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "archive-symlink-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    const secretPath = buildPath(root, "secret.txt");
    const linkPath = buildPath(root, "link.txt");
    const archivePath = buildPath(root, "links.tar");
    write(secretPath, "TOPSECRET-CONTENT");
    auto linked = execute(["ln", "-s", secretPath, linkPath]);
    assert(linked.status == 0, linked.output);
    auto created = execute(["tar", "-cf", archivePath, "-C", root,
        "secret.txt", "link.txt"]);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);

    assert(blob.archiveSpecs.length == 2);
    bool sawSecret;
    bool sawLink;
    foreach (entry; blob.archiveSpecs)
        if (entry.fileName == "secret.txt")
        {
            sawSecret = true;
            assert(entry.checkSums.hasDigests);
        }
        else if (entry.fileName == "link.txt")
        {
            sawLink = true;
            assert(!entry.checkSums.hasDigests,
                "a symlink member must not expose its target digest");
        }
    assert(sawSecret);
    assert(sawLink);
}

@("deep archive scan indexes plain RAR archives")
unittest
{
    import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir,
        write;
    import std.path : buildPath;
    import std.process : Config, execute, executeShell;
    import std.uuid : randomUUID;

    if (executeShell("command -v rar").status != 0
        || executeShell("command -v unrar").status != 0)
        return;
    const root = buildPath(tempDir(), "archive-rar-deep-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    write(buildPath(root, "first.txt"), "first rar payload");
    write(buildPath(root, "second.txt"), "second rar payload");
    const archivePath = buildPath(root, "plain.rar");
    auto created = execute(["rar", "a", "-idq", "-ep1", archivePath,
        "first.txt", "second.txt"], null, Config.none, size_t.max, root);
    assert(created.status == 0, created.output);

    auto blob = new NamedBinaryBlob(archivePath,
        cast(size_t) getSize(archivePath), SysTime(1_234_567));
    auto cache = new MemberContentCache(buildPath(root, "cache"));
    scope (exit)
        cache.close();
    updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);

    assert(blob.archiveSpecs.length == 2);
    bool sawFirst;
    foreach (entry; blob.archiveSpecs)
    {
        if (entry.fileName == "first.txt")
        {
            sawFirst = true;
            assert(entry.checkSums.hasDigests, entry.fileName);
        }
    }
    assert(sawFirst);
}

@("deep archive scan fingerprints selectable duplicate occurrences")
unittest
{
	import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir;
	import std.path : buildPath;
	import std.process : execute, executeShell;
	import std.uuid : randomUUID;

	if (executeShell("command -v python3").status != 0)
		return;
	const auto root = buildPath(tempDir(), "archive-cache-duplicate-scan-"
		~ randomUUID().toString());
	const auto archivePath = buildPath(root, "duplicate.zip");
	mkdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	const auto createScript = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); "
		~ "z.writestr('same.txt', 'first occurrence'); "
		~ "z.writestr('same.txt', 'second occurrence'); z.close()";
	const auto created = execute(["python3", "-c", createScript, archivePath]);
	assert(created.status == 0, created.output);
	auto blob = new NamedBinaryBlob();
	blob.fileSize = cast(size_t) getSize(archivePath);
	blob.fileSpecs = [new FileSpec(archivePath, "")];
	auto cache = new MemberContentCache(buildPath(root, "cache"));
	scope (exit)
		cache.close();
	updateArchives(blob, true, true, null, null, null, 0, 8, "", cache);
	assert(blob.archiveSpecs.length == 2);
	assert(blob.archiveSpecs[0].occurrence == 0);
	assert(blob.archiveSpecs[1].occurrence == 1);
	assert(blob.archiveSpecs[0].checkSums.hasDigests);
	assert(blob.archiveSpecs[1].checkSums.hasDigests);
}
