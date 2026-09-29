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

public import dosierskanilo.logging;
public import dosierskanilo.options;
public import dosierskanilo.progress;
public import dosierskanilo.metadata.digests;
public import dosierskanilo.metadata.fileutilsig;
public import dosierskanilo.metadata.mediainfosig;
public import dosierskanilo.metadata.torrentinfo;
public import dosierskanilo.model.archivespec;
public import dosierskanilo.model.checksums;
public import dosierskanilo.model.filespec;
public import dosierskanilo.model.namedbinaryblobcatalog;
public import dosierskanilo.model.namedbinaryblob;
public import dosierskanilo.service.analyze;
public import dosierskanilo.service.scanning;
public import dosierskanilo.service.storageio;
public import dosierskanilo.repository;
