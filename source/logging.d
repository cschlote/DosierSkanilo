/** Simple logging wrapper.
 *
 * This module writes log output to stdout. Some functions always log; others
 * only log when the command-line verbose flag is enabled. Output is flushed
 * after each call.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, Released under CC-BY-NC-SA 4.0 license, 2018
 * License: CC-NC-BY 4.0
 */
module logging;

import std.stdio : writef, writeln, writefln, write, stdout;

/** Logging with format but no newline
 *
 * Params:
 *   args = args passed to writeln
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

/** Logging with format
 *
 * Params:
 *   args = args passed to writeln
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

/** Logging without format
 *
 * Params:
 *   args = args passed to writeln
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

/** Logging without format and without newline
 *
 * Params:
 *   args = args passed to writeln
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

/** Logging with format and without newline, but only when verbose output is enabled
 *
 * Params:
 *   args = args passed to writeln
 */
void logFVerbose(T...)(T args)
{
    version (unittest)
    {
    }
    else
    {
        import commandline  : argsArray;

        if (argsArray.argVerboseOutputs)
            writef(args);
        stdout.flush;
    }
}

/** Logging with format, but only when verbose output is enabled
 *
 * Params:
 *   args = args passed to writeln
 */
void logFLineVerbose(T...)(T args)
{
    version (unittest)
    {
    }
    else
    {
        import commandline  : argsArray;

        if (argsArray.argVerboseOutputs)
            writefln(args);
        stdout.flush;
    }
}

/** Logging without format, but only when verbose output is enabled
 *
 * Params:
 *   args = args passed to writeln
 */
void logLineVerbose(T...)(T args)
{
    version (unittest)
    {
    }
    else
    {
        import commandline  : argsArray;

        if (argsArray.argVerboseOutputs)
            writeln(args);
        stdout.flush;
    }
}

/** Logging without format and without newline, but only when verbose output is enabled
 *
 * Params:
 *   args = args passed to writeln
 */
void logVerbose(T...)(T args)
{
    version (unittest)
    {
    }
    else
    {
        import commandline  : argsArray;

        if (argsArray.argVerboseOutputs)
        {
            write(args);
            stdout.flush;
        }
    }
}
