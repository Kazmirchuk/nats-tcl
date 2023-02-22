# Running tests

The library has been tested on Windows 10 using the latest pre-built Tcl available from ActiveState (Tcl 8.6.12, Tcllib 1.20, TLS 1.7.16) and on OpenSUSE LEAP 15.4 using Tcl from the distribution repos (Tcl 8.6.12, Tcllib 1.20, TLS 1.7.22). It might work on earlier versions of Tcllib/TLS too.

Regarding the NATS server version, all tests pass against v2.9.14. "Core NATS" tests (all *.test files except jet_stream.test, jet_stream_mgmt.test, pubsub.test, cluster.test) also pass against NATS v1.4.1. Of course, JetStream and message headers require NATS 2.2+.

Both `nats-server` and `nats` [CLI](https://github.com/nats-io/natscli) must be available in your `$PATH`. I've tested with NATS CLI v0.0.35.

The tests are based on the standard Tcl unit testing framework, [tcltest](https://www.tcl.tk/man/tcl8.6/TclCmd/tcltest.htm). Simply run `tclsh tests/all.tcl` and the tests will be executed one after another. The test framework will start and stop NATS server as needed.

And this is how you can run just one test script and save the log to a file:
```bash
tclsh tests/all.tcl -file basic.test -outfile test.log
```

If you get debug output in stderr from C code in the TLS package, it must have been compiled with `#define TCLEXT_TCLTLS_DEBUG` (seems to be default in the CentOS/EPEL repo). You'll need to recompile TclTLS yourself without this flag.
