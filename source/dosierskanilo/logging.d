/** Logging helpers shared by the library and CLI.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.logging;

import std.stdio : stdout, write, writef, writefln, writeln;

/** Global verbose-output flag used by logging helpers. */
__gshared bool verboseEnabled;

/** Enable or disable verbose log output.
 *
 * This flag is shared by the library and CLI logging helpers.
 *
 * Params:
 *   enabled = `true` to enable verbose logging, `false` to disable it.
 */
void setVerboseOutputs(bool enabled) nothrow
{
	verboseEnabled = enabled;
}

/** Return the current verbose-output state. */
bool isVerboseOutputs() nothrow
{
	return verboseEnabled;
}

/** Write formatted text without a trailing newline.
 *
 * This is a thin wrapper around `std.stdio.writef` that flushes stdout after
 * each call.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writef`.
 */
void logF(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		writef(args);
		stdout.flush;
	}
}

/** Write formatted text with a trailing newline.
 *
 * This is a thin wrapper around `std.stdio.writefln` that flushes stdout after
 * each call.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writefln`.
 */
void logFLine(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		writefln(args);
		stdout.flush;
	}
}

/** Write text with a trailing newline.
 *
 * This is a thin wrapper around `std.stdio.writeln` that flushes stdout after
 * each call.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writeln`.
 */
void logLine(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		writeln(args);
		stdout.flush;
	}
}

/** Write text without a trailing newline.
 *
 * This is a thin wrapper around `std.stdio.write` that flushes stdout after
 * each call.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.write`.
 */
void log(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		write(args);
		stdout.flush;
	}
}

/** Write formatted verbose text without a trailing newline.
 *
 * Output is emitted only while verbose logging is enabled.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writef`.
 */
void logFVerbose(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		if (verboseEnabled)
			writef(args);
		stdout.flush;
	}
}

/** Write formatted verbose text with a trailing newline.
 *
 * Output is emitted only while verbose logging is enabled.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writefln`.
 */
void logFLineVerbose(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		if (verboseEnabled)
			writefln(args);
		stdout.flush;
	}
}

/** Write verbose text with a trailing newline.
 *
 * Output is emitted only while verbose logging is enabled.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.writeln`.
 */
void logLineVerbose(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		if (verboseEnabled)
			writeln(args);
		stdout.flush;
	}
}

/** Write verbose text without a trailing newline.
 *
 * Output is emitted only while verbose logging is enabled.
 *
 * Params:
 *   args = arguments forwarded to `std.stdio.write`.
 */
void logVerbose(T...)(T args)
{
	version (unittest)
	{
	}
	else
	{
		if (verboseEnabled)
		{
			write(args);
			stdout.flush;
		}
	}
}

@("logging verbose flag toggles")
unittest
{
	bool original = isVerboseOutputs();
	scope (exit)
		setVerboseOutputs(original);

	setVerboseOutputs(false);
	assert(!isVerboseOutputs);

	setVerboseOutputs(true);
	assert(isVerboseOutputs);
}
