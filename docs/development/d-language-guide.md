---
title: D Language Guide
description: D programming and DDoc conventions for DosierSkanilo.
area: development
---

# D Language Guide

## Style

- Prefer Phobos before adding a dependency.
- Keep APIs small, explicit, and value-oriented where practical.
- Match the nearby source style and keep changes focused.
- Use `immutable`, `const`, and `scope` when they make ownership or lifetime clearer.
- Add `@safe`, `nothrow`, `pure`, or `@nogc` when the contract is natural and can be maintained.
- Use named constants for non-obvious limits; do not hide format limits in literals.
- Keep data handling code independent of UI and application-global state.

## Module structure

- The path, filename, and module declaration must agree.
- Every `.d` file starts with a compact block DDoc comment immediately before its `module` declaration.
- The first sentence names the module's domain and purpose.
- End the module header with `Authors:`, `Copyright:`, and `License:`.
- Avoid generic module names such as `utils` unless the responsibility is truly cross-cutting.

Example:

```d
/** Big-endian legacy reader for DosierSkanilo payload bytes.
 *
 * Authors: DosierSkanilo contributors
 * Copyright: 1990-2026, Carsten Schlote
 * License: DosierSkanilo project license
 */
module dosierskanilo.format.byte_reader;
```

## DDoc

- Use block DDoc for modules, structs, classes, functions, methods, and meaningful private helpers.
- Describe why a type exists, not only the names of its fields.
- Document every field that carries format, ownership, or lifecycle meaning.
- Document every function with `Params:` and `Returns:`; add `Throws:` where applicable.
- State sentinel values, units, byte order, ownership, and optionality explicitly.
- Keep uncertain semantics marked as unresolved rather than presenting guesses as facts.
- Comments and source documentation use English for consistency with the codebase.

## Tests

- Put a `unittest` directly after the free function it verifies where possible.
- Test valid values, boundary values, truncation, invalid identifiers, and overflow for format code.
- Keep tests in non-package child modules so DUB's generated test root discovers them.
- After adding a test, confirm that the test count or named output proves it ran.
- Avoid making UI startup a prerequisite for parser unit tests.

## Type initialization and ownership

- `string.init` is `null`, not an empty string.
- Floating-point `.init` values are `NaN`.
- Initialize model fields explicitly when an empty string or numeric sentinel matters.
- Never cast legacy bytes directly onto a D struct; host layout and alignment are not the file format.
- The parser owns copied model data. Raw input buffers may be discarded after parsing.

## Logging

The current skeleton has no runtime logging layer. When one is introduced,
messages must be concise and include file path and byte offset for parse errors.
Milestone messages should be infrequent; detailed byte-level tracing should be
opt-in and never the default output.