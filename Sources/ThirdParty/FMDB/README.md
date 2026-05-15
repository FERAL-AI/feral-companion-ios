# FMDB (vendored — public-domain headers + additions)

This directory vendors the four FMDB source files that the JieLi
`JWBle.framework` link target depends on at runtime:

- `FMDB.h` — umbrella header
- `FMDatabase.h` — class declaration (header-only here; the .o is shipped inside `JWBle.framework`)
- `FMDatabaseAdditions.h` — category interface
- `FMDatabaseAdditions.m` — category implementation

`JWBle.framework` bundles its own `FMDatabase.o` and `FMResultSet.o` but
**not** the `(FMDatabaseAdditions)` category. The vendor demo registers
the additions category methods (`getTableSchema:`, `intForQuery:`, etc.)
against the FMDatabase class shipped inside the framework. Without
`FMDatabaseAdditions.m` linked into the host app, JieLi's
`JWBleDBModel.createTable` crashes the app at SDK init with:

```
*** -[FMDatabase getTableSchema:]: unrecognized selector
```

That is why this category lives in the tracked source tree.

## License

FMDB is distributed under the MIT License (Flying Meat / August "Gus"
Mueller; see <https://github.com/ccgus/fmdb/blob/master/LICENSE.txt>).
Copying these four files into a FERAL distribution is permitted; the
notice below is reproduced verbatim:

```
If you are using FMDB in your project, I'd love to hear about it.
Let Gus know by sending an email to gus@flyingmeat.com.

And if you happen to come across either Gus Mueller or Rob Ryan in a
bar, you might consider purchasing a drink of their choosing if FMDB
has been useful to you.

(The FMDB source itself is under the MIT License.)
```

## Compile guard

The additions `.m` file references the FMDatabase symbol which only
resolves at link time when `Vendor/JWBle.framework` is present. The
file is therefore wrapped in `#if __has_include(<JWBle/JWBle.h>)` so
stub-mode builds (no vendor drop) link successfully with an empty
translation unit and the rest of the app behaves correctly.
