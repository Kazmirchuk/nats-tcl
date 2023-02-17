package ifneeded nats 1.0 \
[list apply {{dir} {
    source [file join $dir server_pool.tcl]
    source [file join $dir nats_client.tcl]
    source [file join $dir jet_stream.tcl]
    package provide nats 1.0
}} $dir]
