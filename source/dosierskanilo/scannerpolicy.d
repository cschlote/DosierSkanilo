module dosierskanilo.scannerpolicy;

import dosierskanilo.namedbinaryblob;
import std.datetime.systime : SysTime;

/**
 * Determine whether archive scanning should be queued for a blob.
 */
bool shouldQueueArchiveScanJob(bool scanArchivesEnabled, const NamedBinaryBlob obj)
{
    return scanArchivesEnabled && obj.archiveSpecs is null;
}

@("shouldQueueArchiveScanJob")
unittest
{
    auto blob = new NamedBinaryBlob("test/dummy-text-file.txt", 1, SysTime(4_237_892));

    assert(!shouldQueueArchiveScanJob(false, blob));
    assert(shouldQueueArchiveScanJob(true, blob));

    blob.archiveSpecs = [new ArchiveSpec()];
    assert(!shouldQueueArchiveScanJob(true, blob));
}
