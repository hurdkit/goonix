#!/usr/bin/env tclsh
# Compare helper streams by logical bytes, not by scheduler-dependent reads.
proc read_capture {path} {
    set file [open $path r]
    fconfigure $file -translation binary -encoding binary
    set data [read $file]
    close $file
    set streams [dict create stdin {} stdout {} fd4 {}]
    set metadata {}
    foreach line [split $data \n] {
        if {[regexp {^(stdin|stdout|fd4) ([0-9]+) ([0-9a-f]*)$} $line -> direction size hex]} {
            set bytes [binary decode hex $hex]
            if {[string length $bytes] != $size} { error "bad capture length in $path" }
            dict append streams $direction $bytes
        } elseif {$line ne ""} {
            append metadata "$line\n"
        }
    }
    return [list $streams $metadata]
}
if {[llength $argv] != 2} { error "usage: normalize.tcl CXX HS" }
lassign $argv cxx hs
lassign [read_capture $cxx] cxx_streams cxx_metadata
lassign [read_capture $hs] hs_streams hs_metadata
if {$cxx_metadata ne $hs_metadata} {
    puts stderr "metadata differs:\nC++:\n$cxx_metadata\nHaskell:\n$hs_metadata"
    exit 1
}
foreach direction {stdin stdout fd4} {
    set left [dict get $cxx_streams $direction]
    set right [dict get $hs_streams $direction]
    if {$left ne $right} {
        puts stderr "$direction differs:\nC++: [binary encode hex $left]\nHS: [binary encode hex $right]"
        exit 1
    }
}
puts "identical logical helper streams: [file tail [file dirname $cxx]]/[file tail $cxx]"
