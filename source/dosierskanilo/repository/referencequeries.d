/** Directory, file, archive-entry, and torrent reads over the repository.
 *
 * Filters, cursors, and virtual archive references are resolved in SQL.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.referencequeries;

import d2sqlite3;
import std.algorithm : reverse;
import std.algorithm.searching : canFind;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : baseName;
import std.string : empty;
import std.typecons : Nullable;
import dosierarkivo.archive : archiveIndexVersion, archivePathFilterSql,
    archivePathSeparator, parseArchiveVirtualPath, ParsedArchiveVirtualPath;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.archiveindex : isVirtualFileReferenceSql;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;
import dosierskanilo.repository.transfer : parentArchivePath;
import dosierskanilo.repository.catalogreads : loadCatalogFromDatabase,
    decodeBase64;

/** List immediate child directories without materializing the catalog.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Parent selection, filters and page bounds.
 * Returns: Matching directories ordered by relative path; empty when the parent
 *     has no matching children.
 */
RepositoryDirectory[] listDirectoriesFromDatabase(ref Database db,
    RepositoryDirectoryQuery options)
{
    auto statement = db.prepare(
        "SELECT d.id, d.parent_id, d.name, d.relative_path, "
        ~         "(SELECT count(*) FROM directories child WHERE child.parent_id = d.id), "
        ~ "(SELECT count(*) FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "WHERE f.directory_id = d.id" ~ directoryFileFilterSql(options) ~ "), "
        ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE "
        ~ "(f.relative_path = d.relative_path "
        ~ "OR (f.relative_path >= d.relative_path || '/' "
        ~ "AND f.relative_path < d.relative_path || '0')) "
        ~ directoryFileFilterSql(options) ~ "), 0) "
        ~ "FROM directories d WHERE "
        ~ (options.parentId == 0 ? "d.parent_id IS NULL" : "d.parent_id = :parent_id")
        ~ directoryFilterSql(options)
        ~ " ORDER BY d.relative_path LIMIT :limit OFFSET :offset");
    if (options.parentId != 0)
        statement.bind(":parent_id", options.parentId);
    bindDirectoryFilter(statement, options);
    statement.bind(":limit", cast(long) options.limit);
    statement.bind(":offset", cast(long) options.offset);

    RepositoryDirectory[] result;
    foreach (row; statement.execute())
    {
        auto parent = row.peek!(Nullable!long)(1);
        result ~= RepositoryDirectory(row.peek!long(0), parent.isNull ? 0 : parent.get,
            row.peek!string(2), row.peek!string(3), cast(size_t) row.peek!long(4),
            cast(size_t) row.peek!long(5), cast(ulong) row.peek!long(6));
    }
    return result;
}

/** Count all physical file references in the repository.
 *
 * Archive members are excluded.
 *
 * Params:
 *     db = Open repository database to read.
 * Returns: The number of stored physical file references.
 */
size_t countPhysicalFileReferences(ref Database db)
{
    auto result = db.execute("SELECT count(*) FROM file_refs WHERE "
        ~ "NOT (" ~ isVirtualFileReferenceSql("relative_path") ~ ")");
    return cast(size_t) result.front.peek!long(0);
}

/** Count root children and aggregate repository size without loading file rows.
 *
 * Params:
 *     db = Open repository database to read.
 * Returns: Root directory count, physical root-file count and aggregate size
 *     across all physical file references.
 */
RepositoryRootSummary loadRootSummaryFromDatabase(ref Database db)
{
    auto result = db.execute("SELECT "
        ~ "(SELECT count(*) FROM directories WHERE parent_id IS NULL), "
        ~ "(SELECT count(*) FROM file_refs WHERE directory_id IS NULL AND "
        ~ "NOT (" ~ isVirtualFileReferenceSql("relative_path") ~ ")), "
        ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE "
        ~ "NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")), 0)");
    auto row = result.front;
    return RepositoryRootSummary(cast(size_t) row.peek!long(0),
        cast(size_t) row.peek!long(1), cast(ulong) row.peek!long(2));
}

/** Build the SQL fragment that filters file references for directory listings.
 *
 * Params:
 *     options = Directory query filters to translate.
 *     fileAlias = SQL alias of the `file_refs` table.
 *     blobAlias = SQL alias of the joined `blobs` table.
 * Returns: A fragment starting with " AND" for each active filter, or an empty
 *     string when no file-level filter is active.
 */
private string directoryFileFilterSql(RepositoryDirectoryQuery options,
    string fileAlias = "f", string blobAlias = "b")
{
    string sql;
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql(fileAlias ~ ".relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= " AND " ~ archivePathFilterSql(fileAlias ~ ".relative_path",
            ":directory_text", options.caseSensitive);
    if (options.availableOnly)
        sql ~= " AND " ~ fileAlias ~ ".exists_on_disk = 1";

    string[] media;
    if (options.video) media ~= "EXISTS (SELECT 1 FROM media_video_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.audio) media ~= "EXISTS (SELECT 1 FROM media_audio_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.image) media ~= "EXISTS (SELECT 1 FROM media_image_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.textStream) media ~= "EXISTS (SELECT 1 FROM media_text_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (media.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ media.join(" OR ") ~ ")"
            : " AND (" ~ media.join(" OR ") ~ ")";

    string[] other;
    if (options.fileType) other ~= "(" ~ blobAlias ~ ".file_type IS NOT NULL AND length("
        ~ blobAlias ~ ".file_type) > 0)";
    if (options.archive) other ~= "EXISTS (SELECT 1 FROM metadata_status a "
        ~ "WHERE a.blob_id = " ~ blobAlias ~ ".id AND a.metadata_kind = 'archives' "
        ~ "AND a.state IN ('completed', 'empty'))";
    if (options.torrent) other ~= "EXISTS (SELECT 1 FROM torrent_info t WHERE t.blob_id = "
        ~ blobAlias ~ ".id)";
    if (other.length > 0)
        sql ~= " AND (" ~ other.join(" OR ") ~ ")";
    return sql;
}

/** Build the SQL fragment that keeps only directories with matching descendants.
 *
 * Params:
 *     options = Directory query filters to translate.
 * Returns: A recursive `EXISTS` fragment starting with " AND", or an empty
 *     string when no descendant filter is active.
 */
private string directoryFilterSql(RepositoryDirectoryQuery options)
{
    if (options.text.empty && !options.video && !options.audio && !options.image
        && !options.textStream && !options.fileType && !options.archive
        && !options.torrent && !options.availableOnly)
        return "";

    string sql = " AND EXISTS (WITH RECURSIVE subtree(id) AS (SELECT d.id UNION ALL "
        ~ "SELECT child.id FROM directories child JOIN subtree s ON child.parent_id = s.id) "
        ~ "SELECT 1 FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "WHERE f.directory_id IN (SELECT id FROM subtree)";
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= " AND " ~ archivePathFilterSql("f.relative_path",
            ":directory_text", options.caseSensitive);
    if (options.availableOnly)
        sql ~= " AND f.exists_on_disk = 1";

    string[] media;
    if (options.video) media ~= "EXISTS (SELECT 1 FROM media_video_streams x WHERE x.blob_id = b.id)";
    if (options.audio) media ~= "EXISTS (SELECT 1 FROM media_audio_streams x WHERE x.blob_id = b.id)";
    if (options.image) media ~= "EXISTS (SELECT 1 FROM media_image_streams x WHERE x.blob_id = b.id)";
    if (options.textStream) media ~= "EXISTS (SELECT 1 FROM media_text_streams x WHERE x.blob_id = b.id)";
    if (media.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ media.join(" OR ") ~ ")"
            : " AND (" ~ media.join(" OR ") ~ ")";

    string[] other;
    if (options.fileType) other ~= "(b.file_type IS NOT NULL AND length(b.file_type) > 0)";
    if (options.archive) other ~= "EXISTS (SELECT 1 FROM metadata_status a "
        ~ "WHERE a.blob_id = b.id AND a.metadata_kind = 'archives' "
        ~ "AND a.state IN ('completed', 'empty'))";
    if (options.torrent) other ~= "EXISTS (SELECT 1 FROM torrent_info t WHERE t.blob_id = b.id)";
    if (other.length > 0)
        sql ~= " AND (" ~ other.join(" OR ") ~ ")";
    return sql ~ ")";
}

/** Bind the text parameter used by the directory filter fragments.
 *
 * Params:
 *     statement = Prepared directory query statement.
 *     options = Directory query filters whose text is bound when non-empty.
 */
private void bindDirectoryFilter(ref Statement statement, RepositoryDirectoryQuery options)
{
    if (!options.text.empty)
        statement.bind(":directory_text", options.text);
}

/** List immediate file references without materializing blob details.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Directory selection, filters and page bounds.
 * Returns: The matching file references in query order; empty when nothing
 *     matches.
 */
RepositoryFile[] listFilesFromDatabase(ref Database db, RepositoryFileQuery options)
{
    return listFilesPageFromDatabase(db, options).files;
}

/** Convert a page size to a SQLite LIMIT value; -1 means "all rows".
 *
 * Params:
 *     limit = Requested page size.
 *     fetchExtra = Reserve room for one look-ahead row when true.
 * Returns: The LIMIT value, or -1 when `limit` is effectively unbounded.
 */
package long pageLimitSql(size_t limit, bool fetchExtra = false)
{
    if (limit >= cast(size_t) long.max)
        return -1L;
    const auto value = cast(long) limit;
    return fetchExtra ? value + 1 : value;
}

/** List one keyset-paged file chunk and report continuation state.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Directory selection, filters, sort order and cursor state.
 * Returns: The page of file references with `hasMore` and, when a further page
 *     exists, an opaque `nextCursor`; empty when nothing matches.
 */
RepositoryFilePage listFilesPageFromDatabase(ref Database db, RepositoryFileQuery options)
{
    auto sql = "SELECT f.id, COALESCE(f.directory_id, 0), f.blob_id, "
        ~ "f.relative_path, f.time_last_modified, f.exists_on_disk, b.file_size, "
        ~ "(b.file_type IS NOT NULL AND length(b.file_type) > 0), "
        ~ "EXISTS (SELECT 1 FROM media_signatures ms WHERE ms.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM metadata_status ar WHERE ar.blob_id = b.id "
        ~ "AND ar.metadata_kind = 'archives' AND ar.state IN ('completed', 'empty')), "
        ~ "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id), "
        ~ "CASE WHEN " ~ isVirtualFileReferenceSql("f.relative_path") ~ " "
        ~ "THEN 1 ELSE 0 END, 0, 0, 0, 0, '' FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE ";
    /* Do not wrap the column in COALESCE: that would disable
     * idx_file_refs_directory. Zero means the root (NULL) directory. */
    sql ~= options.directoryId == 0
        ? "f.directory_id IS NULL"
        : "f.directory_id = :directory_id";
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= " AND " ~ archivePathFilterSql("f.relative_path", ":text",
            options.caseSensitive);
    if (options.availableOnly)
        sql ~= " AND f.exists_on_disk = 1";
    string[] mediaConditions;
    if (options.video)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id)";
    if (options.audio)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id)";
    if (options.image)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id)";
    if (options.textStream)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id)";
    if (mediaConditions.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ mediaConditions.join(" OR ") ~ ")"
            : " AND (" ~ mediaConditions.join(" OR ") ~ ")";

    string[] otherConditions;
    if (options.fileType)
        otherConditions ~= "(b.file_type IS NOT NULL AND length(b.file_type) > 0)";
    if (options.archive)
        otherConditions ~= "EXISTS (SELECT 1 FROM metadata_status ar "
            ~ "WHERE ar.blob_id = b.id AND ar.metadata_kind = 'archives' "
            ~ "AND ar.state IN ('completed', 'empty'))";
    if (options.torrent)
        otherConditions ~= "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id)";
    if (otherConditions.length > 0)
        sql ~= " AND (" ~ otherConditions.join(" OR ") ~ ")";
    if (!options.afterPath.empty)
    {
        auto pathOperator = options.beforeCursor ? "<" : ">";
        auto sizeOperator = options.beforeCursor ? "<" : ">";
        final switch (options.sortOrder)
        {
        case RepositoryFileSortOrder.pathAscending:
            sql ~= " AND (f.relative_path " ~ pathOperator ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))";
            break;
        case RepositoryFileSortOrder.pathDescending:
            sql ~= " AND (f.relative_path " ~ (options.beforeCursor ? ">" : "<")
                ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? ">" : "<") ~ " :after_id))";
            break;
        case RepositoryFileSortOrder.sizeAscending:
            sql ~= " AND (b.file_size " ~ sizeOperator ~ " :after_size OR (b.file_size = :after_size AND "
                ~ "(f.relative_path " ~ pathOperator ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))))";
            break;
        case RepositoryFileSortOrder.sizeDescending:
            sql ~= " AND (b.file_size " ~ (options.beforeCursor ? ">" : "<") ~ " :after_size OR "
                ~ "(b.file_size = :after_size AND (f.relative_path " ~ pathOperator
                ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))))";
            break;
        }
    }
    final switch (options.sortOrder)
    {
    case RepositoryFileSortOrder.pathAscending:
        sql ~= options.beforeCursor ? " ORDER BY f.relative_path DESC, f.id DESC"
            : " ORDER BY f.relative_path ASC, f.id ASC";
        break;
    case RepositoryFileSortOrder.pathDescending:
        sql ~= options.beforeCursor ? " ORDER BY f.relative_path ASC, f.id ASC"
            : " ORDER BY f.relative_path DESC, f.id DESC";
        break;
    case RepositoryFileSortOrder.sizeAscending:
        sql ~= options.beforeCursor ? " ORDER BY b.file_size DESC, f.relative_path DESC, f.id DESC"
            : " ORDER BY b.file_size ASC, f.relative_path ASC, f.id ASC";
        break;
    case RepositoryFileSortOrder.sizeDescending:
        sql ~= options.beforeCursor ? " ORDER BY b.file_size ASC, f.relative_path DESC, f.id DESC"
            : " ORDER BY b.file_size DESC, f.relative_path ASC, f.id ASC";
        break;
    }
    sql ~= " LIMIT :limit";
    const useOffset = options.afterPath.empty && options.offset > 0;
    if (useOffset)
        sql ~= " OFFSET :offset";
    auto statement = db.prepare(sql);
    if (options.directoryId != 0)
        statement.bind(":directory_id", options.directoryId);
    if (!options.text.empty)
        statement.bind(":text", options.text);
    if (!options.afterPath.empty)
    {
        statement.bind(":after_path", options.afterPath);
        statement.bind(":after_id", options.afterId);
        if (options.sortOrder == RepositoryFileSortOrder.sizeAscending
            || options.sortOrder == RepositoryFileSortOrder.sizeDescending)
            statement.bind(":after_size", cast(long) options.afterSize);
    }
    statement.bind(":limit", pageLimitSql(options.limit, true));
    if (useOffset)
        statement.bind(":offset", cast(long) options.offset);

    RepositoryFilePage page;
    foreach (row; statement.execute())
    {
        auto modified = row.peek!(Nullable!string)(4);
        auto file = RepositoryFile(row.peek!long(0), row.peek!long(1), row.peek!long(2),
            "", row.peek!string(3), cast(ulong) row.peek!long(6),
            modified.isNull ? "" : modified.get, row.peek!long(5) != 0,
            row.peek!long(7) != 0, row.peek!long(8) != 0, row.peek!long(9) != 0,
            row.peek!long(10) != 0, row.peek!long(11) != 0, row.peek!long(12) != 0,
            row.peek!long(13) != 0, row.peek!long(14) != 0,
            row.peek!long(15) != 0, row.peek!long(16), row.peek!long(17),
            row.peek!long(18), cast(size_t) row.peek!long(19),
            row.peek!string(20));
        page.files ~= hydrateVirtualFileReference(db, file);
    }
    if (page.files.length > options.limit)
    {
        page.hasMore = true;
        page.files = page.files[0 .. options.limit];
    }
    if (options.beforeCursor)
        reverse(page.files);
    if (page.hasMore && page.files.length > 0)
    {
        auto cursorFile = options.beforeCursor ? page.files[0] : page.files[$ - 1];
        page.nextCursor = RepositoryFileCursor(cursorFile.relativePath,
            cursorFile.id, cursorFile.size);
    }
    return page;
}

/** Populate display fields for a file reference, resolving archive members.
 *
 * Every reference gets a display name. A virtual archive member additionally
 * receives its container reference, blob ID and stable identity, looked up from
 * the parent path.
 *
 * Params:
 *     db = Open repository database.
 *     file = File reference with at least its path populated.
 * Returns: The same reference with its display and archive fields filled in.
 */
private RepositoryFile hydrateVirtualFileReference(ref Database db,
    RepositoryFile file)
{
    const auto parsed = parseArchiveVirtualPath(file.relativePath);
    if (!parsed.isVirtual)
    {
        file.name = baseName(parsed.physicalPath);
        return file;
    }

    const auto finalLayer = parsed.entries[$ - 1];
    const auto parentPath = parentArchivePath(file.relativePath);
    auto parent = db.execute("SELECT id, blob_id, relative_path FROM file_refs "
        ~ "WHERE relative_path = ?", parentPath);
    file.name = baseName(finalLayer.relativePath);
    file.archiveMember = true;
    file.archiveEntryId = file.id;
    file.archiveEntryIndex = file.id > 0 ? cast(size_t) file.id : 0;
    file.archiveContainerIdentity = archiveReferenceIdentityForPath(db,
        parentPath);
    if (!parent.empty)
    {
        file.containerReferenceId = parent.front.peek!long(0);
        file.archiveContainerBlobId = parent.front.peek!long(1);
    }
    return file;
}

/** Build the stable identity of the reference stored at `path`.
 *
 * Physical references use a "p" prefix followed by their row ID; virtual
 * references prefix their parent identity and append their own row ID.
 *
 * Params:
 *     db = Open repository database.
 *     path = Stored reference path to resolve.
 *     depth = Current recursion depth used as a guard.
 * Returns: The identity string, or an empty string when no reference exists at
 *     `path`.
 * Throws: `Exception` when nesting exceeds the supported depth of 32.
 */
private string archiveReferenceIdentityForPath(ref Database db, string path,
    size_t depth = 0)
{
    enforce(depth < 32, "Archive reference identity exceeds the maximum depth.");
    auto result = db.execute("SELECT id FROM file_refs WHERE relative_path = ?",
        path);
    if (result.empty)
        return "";
    const auto parsed = parseArchiveVirtualPath(path);
    if (!parsed.isVirtual)
        return "p" ~ result.front.peek!long(0).to!string;
    const auto parentIdentity = archiveReferenceIdentityForPath(db,
        parentArchivePath(path), depth + 1);
    return parentIdentity ~ ":" ~ result.front.peek!long(0).to!string;
}

/** Load one physical reference by its stable repository ID.
 *
 * Params:
 *     db = Open repository database to read.
 *     fileReferenceId = Stable `file_refs.id` value to load.
 * Returns: The populated reference, or `RepositoryFile.init` when no such row
 *     exists.
 */
RepositoryFile loadFileReferenceFromDatabase(ref Database db, long fileReferenceId)
{
    auto result = db.execute("SELECT f.id, COALESCE(f.directory_id, 0), f.blob_id, "
        ~ "f.relative_path, f.time_last_modified, f.exists_on_disk, b.file_size, "
        ~ "(b.file_type IS NOT NULL AND length(b.file_type) > 0), "
        ~ "EXISTS (SELECT 1 FROM media_signatures ms WHERE ms.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM metadata_status ar WHERE ar.blob_id = b.id "
        ~ "AND ar.metadata_kind = 'archives' AND ar.state IN ('completed', 'empty')), "
        ~ "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id) "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id WHERE f.id = ?",
        fileReferenceId);
    if (result.empty)
        return RepositoryFile.init;
    auto row = result.front;
    auto modified = row.peek!(Nullable!string)(4);
    auto file = RepositoryFile(row.peek!long(0), row.peek!long(1), row.peek!long(2),
        "", row.peek!string(3),
        cast(ulong) row.peek!long(6), modified.isNull ? "" : modified.get,
        row.peek!long(5) != 0, row.peek!long(7) != 0,
        row.peek!long(8) != 0, row.peek!long(9) != 0,
        row.peek!long(10) != 0, row.peek!long(11) != 0,
        row.peek!long(12) != 0, row.peek!long(13) != 0,
        row.peek!long(14) != 0, false, 0, 0, 0, 0, "");
    return hydrateVirtualFileReference(db, file);
}

/** List archive entries for one blob without loading the complete blob.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Container blob ID plus page offset and limit.
 * Returns: Deduplicated archive entries ordered by stored path; empty when the
 *     blob has no virtual members or the page is beyond them.
 */
RepositoryArchiveEntry[] listArchiveEntriesFromDatabase(ref Database db,
    RepositoryArchiveQuery options)
{
    string[] containerPaths;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE blob_id = ? "
        ~ "ORDER BY relative_path", options.blobId))
        containerPaths ~= row.peek!string(0).idup;

    if (containerPaths.length == 0 || options.limit == 0)
        return [];

    /* Container ranges live in a temporary table. This avoids two SQL bind
     * variables per reference and lets SQLite apply the page limit after
     * identity deduplication. */
    db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    db.execute("CREATE TEMP TABLE archive_container_prefixes ("
        ~ "prefix TEXT PRIMARY KEY, upper TEXT NOT NULL)");
    scope (exit)
        db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    auto insert = db.prepare("INSERT OR IGNORE INTO "
        ~ "temp.archive_container_prefixes (prefix, upper) VALUES (?, ?)");
    foreach (containerPath; containerPaths)
    {
        /* Stored reference paths are already in canonical display grammar. */
        const prefix = containerPath ~ archivePathSeparator();
        insert.inject(prefix, prefix[0 .. $ - 1] ~ "0");
        insert.reset();
    }

    RepositoryArchiveEntry[] result;
    auto statement = db.prepare(
        "SELECT MIN(f.id), MIN(f.relative_path), f.time_last_modified, "
        ~ "b.id, b.file_size, b.md5, b.sha1, b.xxh64, "
        ~ "substr(f.relative_path, length(p.prefix) + 1) AS member_key "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "JOIN temp.archive_container_prefixes p "
        ~ "ON f.relative_path >= p.prefix AND f.relative_path < p.upper "
        ~ "WHERE " ~ isVirtualFileReferenceSql("f.relative_path") ~ " "
        ~ "GROUP BY member_key ORDER BY member_key LIMIT ? OFFSET ?");
    statement.bind(1, cast(long) options.limit);
    statement.bind(2, cast(long) options.offset);
    foreach (row; statement.execute())
    {
        const auto path = row.peek!string(1);
        ParsedArchiveVirtualPath parsed;
        try
            parsed = parseArchiveVirtualPath(path);
        catch (Exception)
            continue;
        if (!parsed.isVirtual || !containerPaths.canFind(parentArchivePath(path)))
            continue;
        const auto layer = parsed.entries[$ - 1];
        RepositoryArchiveEntry entry;
        entry.id = row.peek!long(0);
        entry.containerBlobId = options.blobId;
        entry.entryIndex = options.offset + result.length;
        entry.occurrence = layer.hasOccurrence ? layer.occurrence : 0;
        entry.name = layer.relativePath;
        entry.relativePath = layer.relativePath;
        entry.hasSafePath = true;
        entry.size = cast(ulong) row.peek!long(4);
        const auto modified = row.peek!(Nullable!string)(2);
        entry.modifiedAt = modified.isNull ? "" : modified.get.idup;
        entry.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(5));
        entry.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(6));
        entry.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(7));
        entry.contentBlobId = row.peek!long(3);
        result ~= entry;
    }
    return result;
}

/** Compute the aggregated archive index summary for one container blob.
 *
 * The summary counts distinct members and complete member fingerprints with a
 * single grouped query instead of paging through the whole index. Container
 * prefixes use the same grammar as `listArchiveEntriesFromDatabase`.
 *
 * Params:
 *     db = Open repository database to read.
 *     blobId = Container blob identity.
 * Returns: Entry and complete-fingerprint counts; zero without members.
 */
RepositoryArchiveSummary archiveEntrySummaryFromDatabase(ref Database db,
    long blobId)
{
    string[] containerPaths;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE blob_id = ? "
        ~ "ORDER BY relative_path", blobId))
        containerPaths ~= row.peek!string(0).idup;

    RepositoryArchiveSummary summary;
    if (containerPaths.length == 0)
        return summary;

    db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    db.execute("CREATE TEMP TABLE archive_container_prefixes ("
        ~ "prefix TEXT PRIMARY KEY, upper TEXT NOT NULL)");
    scope (exit)
        db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    auto insert = db.prepare("INSERT OR IGNORE INTO "
        ~ "temp.archive_container_prefixes (prefix, upper) VALUES (?, ?)");
    foreach (containerPath; containerPaths)
    {
        const prefix = containerPath ~ archivePathSeparator();
        insert.inject(prefix, prefix[0 .. $ - 1] ~ "0");
        insert.reset();
    }

    auto result = db.execute(
        "SELECT COUNT(*), COALESCE(SUM(CASE WHEN md5 IS NOT NULL "
        ~ "AND length(md5) = 16 AND sha1 IS NOT NULL AND length(sha1) = 20 "
        ~ "AND xxh64 IS NOT NULL AND length(xxh64) = 8 THEN 1 ELSE 0 END), 0) "
        ~ "FROM (SELECT MIN(f.id) AS id, b.md5 AS md5, b.sha1 AS sha1, "
        ~ "b.xxh64 AS xxh64, "
        ~ "substr(f.relative_path, length(p.prefix) + 1) AS member_key "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "JOIN temp.archive_container_prefixes p "
        ~ "ON f.relative_path >= p.prefix AND f.relative_path < p.upper "
        ~ "WHERE " ~ isVirtualFileReferenceSql("f.relative_path") ~ " "
        /* Count direct members only; deeper layers belong to nested archives
         * and match listArchiveEntriesFromDatabase's parent filter. */
        ~ "AND instr(substr(f.relative_path, length(p.prefix) + 1), '!/') = 0 "
        ~ "GROUP BY member_key)");
    if (!result.empty)
    {
        auto row = result.front;
        summary.entryCount = cast(size_t) row.peek!long(0);
        summary.completeFingerprints = cast(size_t) row.peek!long(1);
    }
    return summary;
}

/** Load one stable archive-index row without knowing its container blob first.
 *
 * Params:
 *     db = Open repository database to read.
 *     archiveEntryId = Stable `file_refs.id` value of the archive entry.
 * Returns: The populated entry, or `RepositoryArchiveEntry.init` when the row
 *     is missing or is not a virtual archive reference.
 */
RepositoryArchiveEntry loadArchiveEntryFromDatabase(ref Database db,
    long archiveEntryId)
{
    auto result = db.execute("SELECT f.id, f.blob_id, f.relative_path, "
        ~ "f.time_last_modified, b.file_size, b.md5, b.sha1, b.xxh64 "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id WHERE f.id = ?",
        archiveEntryId);
    if (result.empty)
        return RepositoryArchiveEntry.init;
    auto row = result.front;
    ParsedArchiveVirtualPath parsed;
    try
        parsed = parseArchiveVirtualPath(row.peek!string(2));
    catch (Exception)
        return RepositoryArchiveEntry.init;
    if (!parsed.isVirtual)
        return RepositoryArchiveEntry.init;
    const auto layer = parsed.entries[$ - 1];
    const auto containerPath = parentArchivePath(row.peek!string(2));
    auto container = db.execute("SELECT blob_id FROM file_refs WHERE relative_path = ?",
        containerPath);
    RepositoryArchiveEntry entry;
    entry.id = row.peek!long(0);
    entry.containerBlobId = container.empty ? 0
        : container.front.peek!long(0);
    entry.entryIndex = cast(size_t) row.peek!long(0);
    entry.occurrence = layer.hasOccurrence ? layer.occurrence : 0;
    entry.name = layer.relativePath;
    entry.relativePath = layer.relativePath;
    entry.hasSafePath = true;
    entry.size = cast(ulong) row.peek!long(4);
    const auto modified = row.peek!(Nullable!string)(3);
    entry.modifiedAt = modified.isNull ? "" : modified.get;
    entry.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(5));
    entry.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(6));
    entry.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(7));
    entry.contentBlobId = row.peek!long(1);
    return entry;
}

/** List torrent files for one blob without loading torrent metadata.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Torrent blob ID plus page offset and limit.
 * Returns: The requested torrent file entries in file-index order; empty when
 *     the torrent has no files or the page is beyond them.
 */
RepositoryTorrentFile[] listTorrentFilesFromDatabase(ref Database db,
    RepositoryTorrentQuery options)
{
    auto statement = db.prepare("SELECT id, relative_path, file_size "
        ~ "FROM torrent_files WHERE torrent_blob_id = ? ORDER BY file_index "
        ~ "LIMIT ? OFFSET ?");
    statement.bind(1, options.blobId);
    statement.bind(2, cast(long) options.limit);
    statement.bind(3, cast(long) options.offset);
    RepositoryTorrentFile[] result;
    foreach (row; statement.execute())
        result ~= RepositoryTorrentFile(row.peek!long(0), row.peek!string(1),
            cast(ulong) row.peek!long(2));
    return result;
}

@("repository transfer queries")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size, file_type) VALUES "
        ~ "(1, 128, 'application/zip'), "
        ~ "(2, 11, NULL), "
        ~ "(3, 32, NULL)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, 1, 'archives/container.zip', '2026-01-01T00:00:00', 1, ?), "
        ~ "(2, 2, 1, 'archives/container.zip!/nested/readme.txt', "
        ~ "'2026-01-01T00:00:00', 1, ?), "
        ~ "(3, 3, NULL, 'root.txt', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(1, 'archives', 'completed', ?, ?, NULL)",
        archiveIndexVersion ~ ":deep", "2026-01-01T00:00:00");
    db.execute("INSERT INTO torrent_info (blob_id, name, magnet_uri, total_size, "
        ~ "is_multi_file, info_hash_hex, announce, piece_length, pieces_count) "
        ~ "VALUES (3, 'demo.torrent', '', 7, 1, '', '', 16384, 1)");
    db.execute("INSERT INTO torrent_files (id, torrent_blob_id, file_index, "
        ~ "relative_path, file_size) VALUES (1, 3, 0, 'files/part1.bin', 7)");

    auto rootSummary = loadRootSummaryFromDatabase(db);
    assert(rootSummary.childDirectoryCount == 1);
    assert(rootSummary.fileCount == 1);
    assert(rootSummary.aggregateSize == 160);

    auto directories = listDirectoriesFromDatabase(db,
        RepositoryDirectoryQuery(0, 0, 10));
    assert(directories.length == 1);
    assert(directories[0].relativePath == "archives");

    auto filesWithoutMembers = listFilesPageFromDatabase(db,
        RepositoryFileQuery(1, 0, 10));
    assert(filesWithoutMembers.files.length == 1);
    assert(filesWithoutMembers.files[0].relativePath == "archives/container.zip");

    auto filesWithMembers = listFilesPageFromDatabase(db,
        RepositoryFileQuery(1, 0, 10, "", false, false, false, false, false,
            false, false, false, false, false, true));
    assert(filesWithMembers.files.length == 2);
    assert(filesWithMembers.files[1].archiveMember);
    assert(filesWithMembers.files[1].archiveContainerBlobId == 1);

    auto archiveEntry = loadArchiveEntryFromDatabase(db, 2);
    assert(archiveEntry.id == 2);
    assert(archiveEntry.containerBlobId == 1);
    assert(archiveEntry.entryIndex == 2);
    assert(archiveEntry.name == "nested/readme.txt");

    auto archiveEntries = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 10));
    assert(archiveEntries.length == 1);
    assert(archiveEntries[0].containerBlobId == 1);
    assert(archiveEntries[0].name == "nested/readme.txt");

    auto torrentFiles = listTorrentFilesFromDatabase(db,
        RepositoryTorrentQuery(3, 0, 10));
    assert(torrentFiles.length == 1);
    assert(torrentFiles[0].relativePath == "files/part1.bin");

    auto blob = loadCatalogFromDatabase(db, "/repo",
        JsonExportOptions("", false, true, true, true, true));
    assert(blob.length == 3);
    assert(blob[0].fileSpecs.length == 1);
    assert(blob[0].archiveIndexKnown);
    assert(blob[1].fileSpecs.length == 1);
    assert(blob[2].torrentInfo !is null);
}

@("SQLite archive ranges include non-BMP members and aggregates")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 100), (2, 1), (3, 2)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, 1, 'archives/emoji.zip', '2026-01-01T00:00:00', 1, ?), "
        ~ "(2, 2, 1, 'archives/emoji.zip!/😀.txt', '2026-01-01T00:00:00', 1, ?), "
        ~ "(3, 3, 1, 'archives/emoji.zip!/z.txt', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(1, 'archives', 'completed', ?, ?, NULL)",
        archiveIndexVersion ~ ":deep", "2026-01-01T00:00:00");

    auto entries = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 10));
    assert(entries.length == 2);
    bool foundEmoji;
    bool foundZ;
    foreach (entry; entries)
    {
        foundEmoji = foundEmoji || entry.name == "😀.txt";
        foundZ = foundZ || entry.name == "z.txt";
    }
    assert(foundEmoji && foundZ);

    RepositoryDirectoryQuery directoryQuery;
    directoryQuery.limit = 10;
    directoryQuery.includeArchiveMembers = true;
    auto directories = listDirectoriesFromDatabase(db, directoryQuery);
    assert(directories.length == 1);
    assert(directories[0].fileCount == 3);
    assert(directories[0].aggregateSize == 103);
}

@("archive path SQL filters accept display and canonical spelling")
unittest
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE paths (path TEXT NOT NULL)");
    db.execute("INSERT INTO paths (path) VALUES (?)", "dir!!/clip!!.mp4");
    db.execute("INSERT INTO paths (path) VALUES (?)", "dir/clip.mp4");
    db.execute("INSERT INTO paths (path) VALUES (?)",
        "container.zip!/member!!.txt");
    auto statement = db.prepare("SELECT count(*) FROM paths WHERE "
        ~ archivePathFilterSql("path", ":text", false));
    statement.bind(":text", "dir!/clip!.mp4");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "dir!!/clip!!.mp4");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "container.zip!/member!.txt");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "missing");
    assert(statement.execute().oneValue!long == 0);
}

@("archive entry listing paginates deduplicated container references")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 100), (2, 1), (3, 2)");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, exists_on_disk) "
        ~ "VALUES (1, 1, 'archives/a.zip', 1), "
        ~ "(2, 2, 'archives/a.zip!/x.txt', 1), "
        ~ "(3, 3, 'archives/a.zip!/y.txt', 1), "
        ~ "(4, 1, 'archives/b.zip', 1), "
        ~ "(5, 2, 'archives/b.zip!/x.txt', 1)");

    auto first = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 1));
    assert(first.length == 1);
    assert(first[0].name == "x.txt");
    assert(first[0].entryIndex == 0);

    auto second = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 1, 1));
    assert(second.length == 1);
    assert(second[0].name == "y.txt");
    assert(second[0].entryIndex == 1);

    auto empty = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 2, 1));
    assert(empty.length == 0);
}
