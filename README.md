# Tcl client library for the NATS message broker

[![License Apache 2.0](https://img.shields.io/badge/License-Apache2-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)

Learn more about NATS [here](https://nats.io) and Tcl/Tk [here](https://www.tcl.tk/).

Feature-wise, the package is comparable to other NATS clients and is inspired by the official [nats.py](https://github.com/nats-io/nats.py) and [nats.go](https://github.com/nats-io/nats.go).

With this package you can bring the power of the publish/subscribe mechanism to your Tcl and significantly simplify development of distributed applications.

The API reference documentation is split into [Core NATS](CoreAPI.md), [JetStream](JsAPI.md) and [Key-Value Store](KvAPI.md).

## Supported platforms

The package is written in pure Tcl, without any C code, and so will work anywhere with `Tcl 8.6` and [Tcllib](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/toc.md). If you need to connect to a NATS server using TLS, of course you will need the [TclTLS](https://core.tcl-lang.org/tcltls/index) package too. On Windows, these packages are normally included in Tcl installers, and on Linux they should be available from your distribution's package manager.

## Installing
The package is available in two forms:
1. As a classic Tcl package using `pkgIndex.tcl`. Download/clone the repository to one of places listed in your `$auto_path`. Or you can extend `$auto_path` with a new folder, e.g.:
```Tcl
lappend auto_path <path>
```
or using an environment variable:
```bash
export TCLLIBPATH=<path>
```
2. As a Tcl module, where all implementation is put into a single *.tm file. This improves package loading time. Note that Tcl modules are loaded from different locations than `$auto_path`. You can check them with the following command:
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
If you are using a "batteries-included" Tcl distribution, like [Magicsplat](https://www.magicsplat.com/tcl-installer/index.html) or [AndroWish](https://www.androwish.org/home/wiki?name=Batteries+Included), you might already have the package.
## Supported features
- Publish and receive messages, also with headers (NATS version 2.2+)
- Synchronous and asynchronous requests (optimized: under the hood a single wildcard subscription is used for all requests)
- Queue groups
- Gather multiple responses to a request
- Publishing and consuming messages from JetStream, providing "at least once" or "exactly once" delivery guarantee
- Management of JetStream streams and consumers
- Support for JetStream based Key-Value Stores
- Standard `configure` method with many options
- Protected connections using TLS
- Automatic reconnection in case of network or server failure
- While the client is trying to reconnect, outgoing messages are buffered in memory and will be flushed as soon as the connection is restored
- Authentication with NATS server using a login+password, an authentication token or a TLS certificate
- Cluster support (including receiving additional server addresses from INFO messages)
- Configurable logging, compatible with the [logger](https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md) package
- (Windows-specific) If the [iocp package](https://iocp.magicsplat.com/) is available, the client will use it for better TCP socket performance
- Extensive test suite with 140+ unit tests, checking nominal use cases, error handling, timings and the wire protocol ensures that the Tcl client behaves in line with official NATS clients

## Examples
Look into the [examples](examples) folder.

## Missing features (in comparison to official NATS clients)
- The new authentication mechanism using NKey & JWT.
- WebSocket is not supported. The only available transport is TCP.
