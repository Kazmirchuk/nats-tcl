# a dummy service that listens on the subject "service"
# after receiving a message it waits for the specified time (ms) and then replies with the same message
package require lambda

proc echo {subj msg reply} {
    lassign $msg delay payload
    if {$payload eq "exit"} {
        exit
    }
    after $delay [lambda {reply payload} {
        $::conn publish $reply $payload
        $::conn ping
    } $reply $payload]
}

set thisDir [file dirname [info script]]
lappend auto_path [file normalize [file join $thisDir ..]]
package require nats

set conn [nats::connection new]
$conn configure -servers nats://localhost:4222
$conn connect
$conn subscribe service -callback echo
$conn ping

vwait forever
