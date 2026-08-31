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

proc key_enter {} { send "\r" }

# Wait while continuously draining the editor's pty output. A plain
# `sleep` leaves the pty master unread; once the small kernel buffer
# fills, the editor blocks in write() and its main loop stops running,
# so anything time-based (swap autosave, external-mtime polling, status
# expiry) never fires. Times out `seconds` after the last output burst.
proc drain {seconds} {
    set t [expr {int(ceil($seconds))}]
    expect -timeout $t -re {.+} { exp_continue } timeout { }
}

# Save-as: Ctrl+S opens prompt, clear CWD, type path, Enter, then quit
proc save_as_quit {path} {
    ctrl s
    sleep 0.5
    # Clear the CWD-seeded prompt
    for {set i 0} {$i < 200} {incr i} { send "\x7f" }
    sleep 0.2
    # Type path
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
set ::skip_count 0

# A case that cannot run here (missing dependency, running as root).
# Counted apart from PASS so an environment gap never reads as green.
proc record_skip {name why} {
    puts stderr "SKIP $name ($why)"
    incr ::skip_count
}

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
    if {$::skip_count > 0} {
        puts stderr "=== $suite_name: $::pass_count/$total passed, $::skip_count skipped ==="
    } else {
        puts stderr "=== $suite_name: $::pass_count/$total passed ==="
    }
    if {$::fail_count > 0} {
        exit 1
    }
    # Every case skipped: report the suite as skipped, not passed.
    if {$total == 0 && $::skip_count > 0} {
        exit 77
    }
}
