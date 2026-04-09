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

/** Enable or disable verbose log output. */
void setVerboseOutputs(bool enabled) nothrow
{
	verboseEnabled = enabled;
}

/** Return the current verbose-output state. */
bool isVerboseOutputs() nothrow
{
	return verboseEnabled;
}

/** Write formatted text without a trailing newline. */
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

/** Write formatted text with a trailing newline. */
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

/** Write text with a trailing newline. */
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

/** Write text without a trailing newline. */
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

/** Write formatted verbose text without a trailing newline. */
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

/** Write formatted verbose text with a trailing newline. */
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

/** Write verbose text with a trailing newline. */
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

/** Write verbose text without a trailing newline. */
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
