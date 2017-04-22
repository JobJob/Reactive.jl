export every, fps, fpswhen, throttle, msnow

zpad2(v) = lpad(v,2,'0')
zpad3(v) = lpad(v,3,'0')
function msnow()
    dt = DateTime(Dates.now())
    "$(Dates.minute(dt) |> zpad2):$(Dates.second(dt) |> zpad2).$(Dates.millisecond(dt) |> zpad3) "
end

"""
    throttle(dt, input, f=(acc,x)->x, init=value(input), reinit=x->x)

Throttle a signal to update at most once every dt seconds. By default, the throttled signal holds the last update in the time window.

This behavior can be changed by the `f`, `init` and `reinit` arguments. The `init` and `f` functions are similar to `init` and `f` in `foldp`. `reinit` is called when a new throttle time window opens to reinitialize the initial value for accumulation, it gets one argument, the previous accumulated value.

For example
    `y = throttle(0.2, x, push!, Int[], _->Int[])`
will create vectors of updates to the integer signal `x` which occur within 0.2 second time windows.

"""
function throttle{T}(dt, node::Signal{T}, f=(acc,x)->x, init=value(node), reinit=x->x; typ=typeof(init), name=auto_name!("throttle $(dt)s", node))
    # we don't add `node` as a parent of throttle, as the action is added to the
    # `node` itself, which pushes to the output node at the appropriate time.
    output = Signal(typ, init, (); name=name)
    throttle_connect(dt, output, node, f, init, reinit)
    output
end

# Aggregate a signal producing an update at most once in dt seconds
function throttle_connect(dt, output, input, f, init, reinit)
    collected = init
    timer = Timer(identity, 0) #dummy timer to initialise
    dopush(_) = begin
        println("$(msnow()): throttle dopush $collected to $output")
        push!(output, collected)
        collected = reinit(collected)
        prevpush = time()
    end
    dopushdbg(dtt) = begin
        println("$(msnow()): timer fired dopushdbg $output")
        dopush(dtt)
    end

    # we add an action to the input node to collect the values and push to the
    # output when the time is right
    prevpush = time()
    function do_throttle(input)
        collected = f(collected,  value(input))
        elapsed = time() - prevpush
        println("$(msnow()): throttle inp: $(input.name), output: $(output.name), val:$(input.value), collected: $collected, elapsed: $elapsed")

        close(timer)
        if elapsed > dt
            dopush(elapsed)
        else
            timer = Timer(dopushdbg, dt-elapsed)
        end
    end
    add_action!(do_throttle, input)
end

"""
    every(dt)

A signal that updates every `dt` seconds to the current timestamp. Consider using `fpswhen` or `fps` if you want specify the timing signal by frequency, rather than delay.
"""
function every(dt; name=auto_name!("every $dt secs"))
    n = Signal(time(), (); name=name)
    every_connect(dt, n)
    n
end

function every_connect(dt, output)
    outputref = WeakRef(output)
    function onerror_close_timer(pushnode, val, error_node, ex)
        print_error(pushnode, val, error_node, ex)
        close(timer)
    end
    timer = Timer(x -> push!(outputref.value, time(), onerror_close_timer), dt, dt)
    finalizer(output, _->close(timer))
    output
end

"""
    fpswhen(switch, rate)

returns a signal which when `switch` signal is true, updates `rate` times every second. If `rate` is not possible to attain because of slowness in computing dependent signal values, the signal will self adjust to provide the best possible rate.
"""
function fpswhen(switch, rate; name=auto_name!("$rate fpswhen", switch))
    # Creates a node and sets up a timer that pushes to the node every 1.0/rate
    # seconds.
    n = Signal(Float64, 0.0, (switch,); name=name)
    fpswhen_connect(rate, switch, n)
    n
end

function setup_next_tick(outputref, switchref, dt, wait_dt)
    Timer(t -> begin
        println("$(msnow()): fpswhen timer $(outputref.value), switchref.value: $(switchref.value)")
        if value(switchref.value)
            push!(outputref.value, dt)
        end
    end, wait_dt)
end

function fpswhen_connect(rate, switch, output)
    prev_time = time()
    dt = 1.0/rate
    outputref = WeakRef(output)
    switchref = WeakRef(switch)
    timer = Timer(identity, 0) #dummy timer to initialise
    function fpswhen_runner(node)
        # this function will run if switch gets a new value (i.e. is "active")
        # and if output is pushed to (assumed to be by the timer)
        println("$(msnow()): fpswhen action $output")
        if switch.value
            start_time = time()
            timer = setup_next_tick(outputref, switchref, start_time-prev_time, dt)
            prev_time = start_time
        else
            close(timer)
            # downstream nodes should activate only when the switch is on
            output.active = false
        end
        # downstream nodes should activate only when the timer pushes to output,
        # not when the switch gets a new value (switch.active flags that case)
        switch.active && (output.active = false)
    end
    add_action!(fpswhen_runner, output)
    # start the timer initially, if switch is on
    switch.value && (timer = setup_next_tick(outputref, switchref, dt, dt))
    # ensure timer stops when node is garbage collected
    finalizer(output, _->close(timer))
end

"""
    fps(rate)

Same as `fpswhen(Input(true), rate)`
"""
fps(rate; name="$rate fps") = fpswhen(Signal(Bool, true, (); name="fps true"), rate; name=name)
