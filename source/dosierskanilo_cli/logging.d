/** Simple logging wrapper.
 *
 * This module writes log output to stdout. Some functions always log; others
 * only log when the command-line verbose flag is enabled. Output is flushed
 * after each call.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo_cli.logging;

public import dosierskanilo.logging;

import std.stdio : stderr, writefln, writeln;

/** Write a formatted CLI diagnostic to stderr. */
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

/** Write a CLI diagnostic to stderr. */
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
