package ifneeded nats 3.0 \
[list apply {{dir} {
    source [file join $dir nats_client.tcl]
    source [file join $dir server_pool.tcl]
    source [file join $dir jet_stream.tcl]
    source [file join $dir key_value.tcl]
    package provide nats 3.0
}} $dir]
