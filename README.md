dover
=====

Dover checks which bindings exported by a Racket package have no Scribble documentation.

```
$ raco pkg install dover
$ raco dover check mypkg-lib
```

It reports missing documentation per module, flags bindings whose docs exist but can't be reached
from the module users require, and can print `defproc`/`defform` stubs for whatever is missing
(`--format stubs`). Use `--min <percent>` to fail a CI build when coverage drops.

Configuration such as bindings to ignore goes in the package's `info.rkt`. See the documentation
for details.

## Repository layout

| Package     | Contents                                   |
|-------------|--------------------------------------------|
| `dover-lib` | Implementation and the `raco dover` command |
| `dover`     | Documentation; installs `dover-lib`        |

To work on it locally:

```
raco pkg install --link dover-lib dover
```

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
