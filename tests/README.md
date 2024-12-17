# Running tests

The library has been tested on Windows 10 using the latest pre-built Tcl available from [Magicsplat](https://www.magicsplat.com) (Tcl 8.6.14, Tcllib 1.21, TLS 1.7.22) and on Ubuntu 24.04 using Tcl from the distribution repos (Tcl 8.6.14, Tcllib 1.21, TLS 1.7.22). It might work on earlier versions of Tcllib/TLS too.

Regarding the NATS server version, all tests pass against v2.10.23. "Core NATS" tests (auth.test, basic.test, extra_opts.test, server_pool.test, subjects_regex.test, tls.test) also pass against NATS v1.4.1. Of course, JetStream and message headers require NATS 2.2+.

Both `nats-server` and `nats` [CLI](https://github.com/nats-io/natscli) must be available in your `$PATH`.

The tests are based on the standard Tcl unit testing framework: [tcltest](https://www.tcl.tk/man/tcl8.6/TclCmd/tcltest.htm). Simply run `tclsh tests/all.tcl` and the tests will be executed one after another. The test framework will start and stop NATS server as needed.

And this is how you can run just one test script and save the log to a file:
```bash
tclsh tests/all.tcl -file basic.test -outfile test.log
```
