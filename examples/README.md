# Examples
The examples cover only basic use cases, so for more details you can look into the tests.
1. [hello_nats.tcl](hello_nats.tcl) - basic publishing and subscribing
2. [requests.tcl](requests.tcl) - sending requests and responding to them; using lambdas for callbacks
3. [logging.tcl](logging.tcl) - tracing public variables and customized logging using the `logger` package from Tcllib.
4. [msg_headers.tcl](msg_headers.tcl) - sending and receiving messages with headers; using `nats::msg` and `nats::header` ensembles
5. [js_msg.tcl](js_msg.tcl) - publishing and consuming messages from JetStream
6. [js_mgmt.tcl](js_mgmt.tcl) - JetStream asset management

Note that the repository as a whole is licensed under Apache 2.0, but the examples are released into the public domain, so you can just copy-paste them into your work.