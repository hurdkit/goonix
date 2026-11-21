#!/usr/bin/env tclsh
# Lossless recorder for helper argv, environment, stdin, stdout/stderr and fd4.
set transcript $env(GOONIX_HELPER_TRANSCRIPT)
set log [open $transcript w]
foreach channel {$log stdin stdout stderr} {
    fconfigure $channel -translation binary -encoding binary -buffering none
}
proc hex {bytes} { binary encode hex $bytes }
proc record {direction bytes} {
    global log
    puts -nonewline $log "$direction [string length $bytes] [hex $bytes]\n"
}
puts $log "argv [hex [join $argv \0]]"
puts $log "cwd [hex [pwd]]"
foreach name {GUIX NIX_STORE_DIR GUIX_DATABASE_DIRECTORY GUIX_STATE_DIRECTORY GUIX_CONFIGURATION_DIRECTORY _NIX_OPTIONS} {
    if {[info exists env($name)]} {
        puts $log "env $name [hex $env($name)]"
    }
}
if {[llength $argv] < 2 || [lindex $argv 0] ni {substitute offload}} {
    puts stderr "record-helper.tcl: unexpected helper arguments: $argv"
    exit 64
}
set root [file dirname [file dirname [file dirname [file dirname [info script]]]]]
set program [file join $root pre-inst-env]
set helper [file join [file dirname [info script]] replay-helper.scm]
set command [list $program guile --no-auto-compile $helper {*}$argv]
# fd4 is bidirectional at the Tcl channel, but the Scheme helper only reads
# its write side.  Forward its bytes to the daemon's own fd4 separately.
if {[catch {open /proc/self/fd/4 w} fd4]} {
    set fd4 stdout
}
fconfigure $fd4 -translation binary -encoding binary -buffering none
set channels [open "| [list {*}$command 2>@1" r+]
fconfigure $channels -translation binary -encoding binary -buffering none
set outputDone 0
fileevent stdin readable {
    set bytes [read stdin 32768]
    if {[string length $bytes]} {
        record stdin $bytes
        puts -nonewline $channels $bytes
        flush $channels
    }
    if {[eof stdin]} {
        catch {chan close $channels write}
        fileevent stdin readable {}
    }
}
fileevent $channels readable {
    set bytes [read $channels 32768]
    if {[string length $bytes]} {
        record stdout $bytes
        puts -nonewline stdout $bytes
        flush stdout
    }
    if {[eof $channels]} {
        set outputDone 1
        fileevent $channels readable {}
    }
}
vwait outputDone
set status [catch {close $channels} message options]
puts $log "status [dict get $options -errorcode]"
close $log
exit $status
