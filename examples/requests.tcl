# EXAMPLE #2: sending requests and responding to them; using lambdas for callbacks

package require nats
package require lambda

set conn [nats::connection new "MyNats"]
$conn configure -servers nats://localhost:4222
$conn connect

# normally this would be a remote service, maybe written in a different language
# for the sake of example, here we respond to our own requests
proc responder {connection subject message replyTo} {
    # echo the same message to the reply-to subject
    $connection publish $replyTo $message
}
# BTW this is how you can pass additional data to any callback, e.g. the connection object
# this is cleaner than accessing a global variable in the callback
$conn subscribe service -callback [list responder $conn]

# a synchronous request blocks until it gets a reply or times out
# default timeout is infinite, so it is recommended to always specify a timeout that is reasonble for a specific use case
# blocking is done in "vwait", so event processing continues; beware of possible nested vwaits, if you use blocking requests in callbacks!
set reply [$conn request service "hello world" -timeout 500]
puts "Sync reply: $reply"

# this is how error handling should be done for sync requests in general
try {
    set reply [$conn request service2 "hello world" -timeout 500]
} trap {NATS ErrTimeout} err {
    # somebody is listening to "service2", but didn't reply on time
    puts $err
} trap {NATS ErrNoResponders} err {
    # nobody is listening to "service2" at all
    puts $err
}

# non-blocking request; the callback will be invoked from the event loop; let's use a lambda for the sake of example
$conn request service "hello world 2" -timeout 500 -callback [lambda {timedOut msg} {
    if {$timedOut} {
        puts "request timed out"
    } else {
        puts "Got a reply: $msg"
    }
}]

# let everything above happen
after 1000 [list set untilDone 1]
vwait untilDone

# this is an advanced technique:
# in a complex application using chained requests, consider using coroutines to avoid nested vwaits and the "callback spaghetti"
# see also https://wiki.tcl-lang.org/page/vwait "Avoiding Nested Calls to vwait"
# the "request" method detects that it is inside a coroutine and enters the "main" vwait instead of creating its own
proc coro_body {connection msg} {
    set reply [$connection request service $msg]
    puts $reply
}
# this coroutines will not interfere with each other or any other event processing in the application,
# even if the remote service is slow
coroutine coro1 coro_body $conn "hello world 3"
coroutine coro2 coro_body $conn "hello world 4"

# let everything above happen
after 1000 [list set untilDone 1]
vwait untilDone

$conn destroy
puts "Done"
