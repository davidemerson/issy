# helpers.tcl -- shared expect procs for issy integration tests

proc ctrl {c} {
    send [format %c [expr {[scan $c %c] - 96}]]
}

proc arrow {dir} {
    switch $dir {
        up    { send "\x1b\[A" }
        down  { send "\x1b\[B" }
        right { send "\x1b\[C" }
        left  { send "\x1b\[D" }
    }
}

proc key_home {} { send "\x1b\[H" }
proc key_end {}  { send "\x1b\[F" }
proc key_delete {} { send "\x1b\[3~" }
proc key_pageup {} { send "\x1b\[5~" }
proc key_pagedown {} { send "\x1b\[6~" }
proc key_escape {} { send "\x1b"; sleep 0.15 }
proc key_enter {} { send "\r" }
proc key_tab {} { send "\t" }
proc key_backspace {} { send "\x7f" }

# Launch issy with --no-config to prevent user config interference
proc launch {issy args} {
    if {[llength $args] == 0} {
        spawn $issy --no-config
    } else {
        eval spawn $issy --no-config $args
    }
    sleep 1
}

# Save (Ctrl+S) and quit (Ctrl+Q) for a file that already has a name
proc save_quit {} {
    ctrl s
    sleep 0.3
    ctrl q
    sleep 0.3
    expect eof
    wait
}

# Save-as: Ctrl+S opens prompt, type path, Enter, then quit
proc save_as_quit {path} {
    ctrl s
    sleep 0.5
    # Type path one char at a time to avoid read buffer issues
    foreach c [split $path ""] {
        send "$c"
    }
    sleep 0.2
    key_enter
    sleep 0.5
    ctrl q
    sleep 0.3
    expect eof
    wait
}

# Force quit (Ctrl+Q twice) without saving
proc force_quit {} {
    ctrl q
    sleep 0.2
    ctrl q
    sleep 0.3
    expect eof
    wait
}

# Read file contents, stripping trailing newline for comparison
proc read_file {path} {
    if {![file exists $path]} {
        return "FILE_NOT_FOUND"
    }
    set fd [open $path r]
    fconfigure $fd -translation binary
    set content [read $fd]
    close $fd
    return $content
}

# Assert file contents match expected string exactly
proc assert_file {path expected testname} {
    set actual [read_file $path]
    if {$actual eq $expected} {
        puts stderr "PASS $testname"
        return 1
    } else {
        puts stderr "FAIL $testname"
        puts stderr "  expected: [string length $expected] bytes: [repr $expected]"
        puts stderr "  actual:   [string length $actual] bytes: [repr $actual]"
        return 0
    }
}

# Safe string representation for debugging
proc repr {s} {
    set out ""
    foreach c [split $s ""] {
        set n [scan $c %c]
        if {$n == 10} {
            append out "\\n"
        } elseif {$n == 9} {
            append out "\\t"
        } elseif {$n < 32 || $n > 126} {
            append out [format "\\x%02x" $n]
        } else {
            append out $c
        }
    }
    return $out
}

# Track pass/fail counts
set ::pass_count 0
set ::fail_count 0

proc record_result {ok} {
    if {$ok} {
        incr ::pass_count
    } else {
        incr ::fail_count
    }
}

proc report_results {suite_name} {
    set total [expr {$::pass_count + $::fail_count}]
    puts stderr ""
    puts stderr "=== $suite_name: $::pass_count/$total passed ==="
    if {$::fail_count > 0} {
        exit 1
    }
}
