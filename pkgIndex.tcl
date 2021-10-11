package ifneeded nats 1.0 \
   "source \[file join [list $dir] server_pool.tcl\] ; \
    source \[file join [list $dir] nats_client.tcl\] ; \
    source \[file join [list $dir] jet_stream.tcl\]"
