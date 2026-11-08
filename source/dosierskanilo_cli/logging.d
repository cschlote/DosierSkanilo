/** Simple logging wrapper for CLI diagnostics.
 *
 * Diagnostic and error helpers write to stderr; command-result output uses the
 * shared `dosierskanilo.logging` helpers and goes to stdout. Some functions
 * always log, while others only log when the command-line verbose flag is
 * enabled. Output is flushed after each call.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo_cli.logging;

public import dosierskanilo.logging;

import std.stdio : stderr, writefln, writeln;

/** Write a formatted CLI diagnostic to stderr.
 *
 * Params:
 *     args = Format string followed by its arguments, forwarded to
 *         `std.stdio.writefln`.
 */
void errorFLine(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		stderr.writefln(args);
		stderr.flush;
	}
}

/** Write a CLI diagnostic to stderr.
 *
 * Params:
 *     args = Values forwarded to `std.stdio.writeln`.
 */
void errorLine(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		stderr.writeln(args);
		stderr.flush;
	}
}

/** Write an informational CLI message to stderr.
 *
 * Params:
 *     args = Format string followed by its arguments, forwarded to
 *         `std.stdio.writefln`.
 */
void noticeFLine(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		stderr.writefln(args);
		stderr.flush;
	}
}
