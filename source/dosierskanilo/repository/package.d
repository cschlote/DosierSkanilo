/** Public repository API for the persistent DosierSkanilo backend.
 *
 * The SQLite implementation is intentionally hidden behind this package
 * facade so CLI and GUI consumers do not depend on d2sqlite3 directly.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository;

public import dosierskanilo.repository.errors;
public import dosierskanilo.repository.analysis;
public import dosierskanilo.repository.repository;
public import dosierskanilo.repository.types;
