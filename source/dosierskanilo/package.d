/** Public package facade for the library-facing dosierskanilo modules.
 *
 * This package exposes the reusable library surface for consumers. The CLI
 * application lives in `dosierskanilo_cli`.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo;

public import dosierskanilo.catalogbackend;
public import dosierskanilo.catalogstatus;
public import dosierskanilo.jsoncatalogbackend;
public import dosierskanilo.logging;
public import dosierskanilo.metadata.digests;
public import dosierskanilo.metadata.fileutilsig;
public import dosierskanilo.metadata.mediainfosig;
public import dosierskanilo.metadata.torrentinfo;
public import dosierskanilo.model.archivespec;
public import dosierskanilo.model.checksums;
public import dosierskanilo.model.filespec;
public import dosierskanilo.model.namedbinaryblob;
public import dosierskanilo.operationrunner;
public import dosierskanilo.operations;
public import dosierskanilo.options;
public import dosierskanilo.progress;
public import dosierskanilo.sqlitecatalogbackend;

// The following modules are no longer re-exported through the public facade.
// Consumers that need them must import them explicitly:
//   import dosierskanilo.repository;
//   import dosierskanilo.service.analyze;
//   import dosierskanilo.service.scanning;
//   import dosierskanilo.service.storageio;
// Prefer `CatalogBackend` and `CatalogBackendFactory` for storage-neutral access.
// See docs/ARCHITECTURE.md section 1.1 and CHANGELOG.md.

/** Legacy alias kept for source compatibility.
 *
 * Prefer `NamedBinaryBlobCatalog` in new code.
 */
alias NamedBinaryBlobWrapper = NamedBinaryBlobCatalog;
