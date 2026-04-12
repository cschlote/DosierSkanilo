/** Catalog for NamedBinaryBlob payloads and global scan metadata.
 *
 * This module re-exports the concrete catalog type so callers can import a
 * dedicated module while the implementation stays with the model type.
 */
module dosierskanilo.model.namedbinaryblobcatalog;

public import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog;

@("NamedBinaryBlobCatalog")
unittest
{
	auto catalog = NamedBinaryBlobCatalog(3, []);
	assert(catalog.dataVersion == 3);
	assert(catalog.dataArray.length == 0);
	assert(catalog.mediaInfoVersion.length == 0);
	assert(catalog.fileUtilityVersion.length == 0);
	catalog.refreshRuntimeMetadata();
	assert(catalog.mediaInfoVersion.length > 0);
	assert(catalog.fileUtilityVersion.length > 0);
}