/** Errors raised by the repository layer.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.errors;

/** Base exception for repository discovery, initialization and storage errors. */
class RepositoryException : Exception
{
    /// Construct an exception with a repository-specific diagnostic message.
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}
