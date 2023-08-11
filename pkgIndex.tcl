package ifneeded nats 2.0.2 \
[list apply {{dir} {
    source [file join $dir server_pool.tcl]
    source [file join $dir nats_client.tcl]
    source [file join $dir jet_stream.tcl]
    source [file join $dir key_value.tcl]
    package provide nats 2.0.2
}} $dir]
