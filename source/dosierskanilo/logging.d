/** Logging helpers shared by the library and CLI.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-BY-NC-SA 4.0
 */
module dosierskanilo.logging;

import std.stdio : stdout, write, writef, writefln, writeln;

__gshared bool verboseEnabled;

void setVerboseOutputs(bool enabled) nothrow
{
	verboseEnabled = enabled;
}

bool isVerboseOutputs() nothrow
{
	return verboseEnabled;
}

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
