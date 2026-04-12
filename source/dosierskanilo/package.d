/** Public package facade for the library-facing dosierskanilo modules.
 *
 * This package exposes the reusable library surface for consumers. The CLI
 * application lives in `dosierskanilo_cli`.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
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
