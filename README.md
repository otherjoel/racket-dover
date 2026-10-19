Dover
=====

Dover checks which bindings exported by a Racket package have no Scribble documentation.

```
$ raco pkg install dover
$ raco dover check mypkg-lib
```

It reports missing documentation per module, warns about bindings that don't connect to their
docs as exported by a module that re-exports them and about `declare-exporting` claims that
aren't true (with a suggested fix for each), and can print `defproc`/`defform` stubs for whatever
is missing (`--format stubs`). In CI, `--min <percent>` fails the build when coverage drops, and
`--strict` fails it when there are warnings.

Configuration such as bindings to ignore goes in the package's `info.rkt`.

**Documentation is at: <https://joeldueck.com/what-about/dover/>**

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
