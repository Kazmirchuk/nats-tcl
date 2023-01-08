# Tcl client library for the NATS message broker

[![License Apache 2.0](https://img.shields.io/badge/License-Apache2-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

Learn more about NATS [here](https://nats.io) and Tcl/Tk [here](https://www.tcl.tk/).

Feature-wise, the package is comparable to other NATS clients and is inspired by the official [nats.py](https://github.com/nats-io/nats.py) and [nats.go](https://github.com/nats-io/nats.go).

With this package you can bring the power of the publish/subscribe mechanism to your Tcl and significantly simplify development of distributed applications.

The API reference documentation is split into [Core NATS](CoreAPI.md) and [JetStream](JsAPI.md).

## Supported platforms

The package is written in pure Tcl, without any C code, and so will work anywhere with `Tcl 8.6` and [Tcllib](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/toc.md). If you need to connect to a NATS server using TLS, of course you will need the [TclTLS](https://core.tcl-lang.org/tcltls/index) package too. On Windows, these packages are normally included in Tcl installers, and on Linux they should be available from your distribution's package manager.

## Installing
The package is available in two forms:
- as a classic Tcl package using pkgIndex.tcl. Download/clone the repository to one of places listed in your `$auto_path`. Or you can extend `$auto_path` with a new folder, e.g.:
```Tcl
lappend auto_path <path>
```
or using an environment variable:
```bash
export TCLLIBPATH=<path>
```
- as a Tcl module, where all implementation is put into a single *.tm file. This improves package loading time. Note that Tcl modules are loaded from different locations than `$auto_path`. You can check them with the following command:
```Tcl
tcl::tm::path list
```
and you can extend this list with:
```Tcl
tcl::tm::path add <path>
```

Both forms can be loaded as:
```Tcl
package require nats
```

## Supported features
- Publish and subscribe to messages, also with headers (NATS version 2.2+)
- Synchronous and asynchronous requests (optimized: under the hood a single wildcard subscription is used for all requests)
- Queue groups
- Gather multiple responses to a request
- Publishing and consuming messages from JetStream, providing "at least once" or "exactly once" delivery guarantees
- JetStream management of streams and consumers
- Standard `configure` method with many options
- Protected connections using TLS
- Automatic reconnection in case of network or server failure
- While the client is trying to reconnect, outgoing messages are buffered in memory and will be flushed as soon as the connection is restored
- Authentication with NATS server using a login+password, an authentication token or a TLS certificate
- Cluster support (including receiving additional server addresses from INFO messages)
- Configurable logging, compatible with the [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) package
- (Windows-specific) If the [iocp package](https://iocp.magicsplat.com/) is available, the client will use it for better TCP socket performance
- Extensive test suite with 120+ unit tests, checking nominal use cases, error handling, timings and the wire protocol ensures that the Tcl client behaves in line with official NATS clients

## Examples
Look into the [examples](examples) folder. They are numbered in the order of difficulty.

## Missing features (in comparison to official NATS clients)
- The new authentication mechanism using NKey & [JWT](https://docs.nats.io/developing-with-nats/security/creds). This one will be difficult to do, because it requires support for _ed25519_ cryptography that is missing in Tcl AFAIK. Please let me know if you need it.

## Running tests

The library has been tested on Windows 10 using the latest pre-built Tcl available from ActiveState (Tcl 8.6.12, Tcllib 1.20, TLS 1.7.16) and on OpenSUSE LEAP 15.4 using Tcl from the distribution repos (Tcl 8.6.12, Tcllib 1.20, TLS 1.7.22). It might work on earlier versions too.

Regarding the NATS server version, all tests pass against v2.9.6. "Core NATS" tests (all *.test files except jet_stream.test, jet_stream_mgmt.test, pubsub.test, cluster.test) also pass against NATS v1.4.1. Of course, JetStream and message headers require NATS 2.2+.

Both `nats-server` and `nats` [CLI](https://github.com/nats-io/natscli) must be available in your `$PATH`. I've tested with NATS CLI v0.0.34.

The tests are based on the standard Tcl unit testing framework, [tcltest](https://www.tcl.tk/man/tcl8.6/TclCmd/tcltest.htm). Simply run `tclsh tests/all.tcl` and the tests will be executed one after another. 

And this is how you can run just one test script and save the log to a file: `tclsh tests/all.tcl -file basic.test -outfile test.log`

To run the TLS tests, you will need to provide certificates yourself in `tests/cert` subfolder. E.g. you can generate them using [mkcert](https://docs.nats.io/nats-server/configuration/securing_nats/tls#self-signed-certificates-for-testing).

If you get debug output in stderr from C code in the TLS package, it must have been compiled with `#define TCLEXT_TCLTLS_DEBUG` (seems to be default in the CentOS/EPEL repo). You'll need to recompile TclTLS yourself without this flag.
