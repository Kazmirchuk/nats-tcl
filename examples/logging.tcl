# EXAMPLE #3: tracing public variables and customized logging

package require nats
package require logger::utils

# we start with demonstrating default logging functions of nats::connection
# the default logging level (severity) is "warn"; let's configure it to "info" and send it to stderr
# you can pass any channel (e.g. a file handle returned by [open]) to -log_chan
set conn [nats::connection new "Connection_1" -log_chan stderr -log_level info]
$conn configure -servers nats://localhost:4222 
$conn connect
# you will see logging about connecting to the NATS server ...
# each message contains a timestamp, logger name (same as connection name - "Connection_1" in this case) and log severity
$conn destroy

# now let's use the logger package from Tcllib
# https://core.tcl-lang.org/tcllib/doc/trunk/embedded/md/tcllib/files/modules/log/logger.md
# the official reference is somewhat cryptic; you can find a better explanation in the book "Tcl 8.5 Network Programming" by Kocjan, Beltowski
# this package allows creating an hierarchy of loggers. Each logger can be identified either by its name ("service name") or object

set mainLogger [logger::init main] ;# this could be the main logger of a large application
set natsLogger [logger::init main::nats] ;# logger only for the NATS connection; it is a "child" of the main logger

# configure the same formatting for both loggers, but different destinations: mainLogger will print to stdout:
logger::utils::applyAppender -appender console -service main -appenderArgs {-conversionPattern {\[[nats::timestamp] %c %p\] %m}}
# and natsLogger will print to a file:
set logFile [open nats.log w]
logger::utils::applyAppender -appender fileAppend -service main::nats -appenderArgs {-outputChannel $::logFile -conversionPattern {\[[nats::timestamp] %c %p\] %m}}
# Note: as of Tcllib 1.20/logger 0.9.4, there's a bug in the logger package regarding logprocs inheritance
# to work around it, I have to apply appenders explicitly to each logger service
# https://stackoverflow.com/questions/75029609/tcl-logger-package-bug-when-inheriting-logproc/75060526#

${mainLogger}::setlevel info ;# changing a logging level of a parent logger propagates to children

# now instead of -log_chan and -log_level we pass the logger object to be used by the connection
set conn [nats::connection new "Connection_2" -logger $natsLogger]
# let's add a non-existing server to the pool just to get more logs about failed connection attempts
$conn configure -servers [list nats://dummy.org:4222 nats://localhost:4222] -randomize false

proc statusTrace {var idx op } {
    upvar 1 $var s
    ${::mainLogger}::info "New status: $s"
    # in a real application you can react to changing connection status
    # e.g. you can close the application altogether, if the connection to NATS is lost
}

# for the sake of example; this trace might be superfluous, because all errors are logged anyway
proc errorTrace {var idx op } {
    upvar 1 $var err
    if {$err ne ""} {
        ${::mainLogger}::error "NATS error: [dict get $err errorMessage]"
    }
}

trace add variable ${conn}::status write statusTrace
trace add variable ${conn}::last_error write errorTrace

# now connect to NATS; you can run nats-server -DV to see verbose logging from it too
$conn connect
$conn disconnect ;# just for the example; the destructor calls disconnect anyway
$conn destroy

${mainLogger}::info "Done"
${mainLogger}::delete ;# clean up the logger and its children
close $logFile
