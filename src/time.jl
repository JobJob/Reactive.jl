export every, fps, fpswhen, throttle

"""
    throttle(dt, input, f=(acc,x)->x, init=value(input), reinit=x->x)

Throttle a signal to update at most once every dt seconds. By default, the throttled signal holds the last update in the time window.

This behavior can be changed by the `f`, `init` and `reinit` arguments. The `init` and `f` functions are similar to `init` and `f` in `foldp`. `reinit` is called when a new throttle time window opens to reinitialize the initial value for accumulation, it gets one argument, the previous accumulated value.

For example
    `y = throttle(0.2, x, push!, Int[], _->Int[])`
will create vectors of updates to the integer signal `x` which occur within 0.2 second time windows.

"""
function throttle{T}(dt, node::Signal{T}, f=(acc,x)->x, init=value(node), reinit=x->x; typ=typeof(init), name=auto_name!("throttle $(dt)s", node))
    output = Signal(typ, init, (node,); name=name)
    # the buck starts here: descendent nodes need to activate when this
    # node is active, not when the parent nodes are active. So we set this
    # as a new root node.
    action_queues[output] = []
    output.roots = ()
    root_nodes[output] = nothing
    throttle_connect(dt, output, node, f, init, reinit)
    output
end

# Aggregate a signal producing an update at most once in dt seconds
function throttle_connect(dt, output, input, f, init, reinit)
    let collected = init, timer = Timer(x->x, 0), prevpush = time()
        dopush(_) = begin
            push!(output, collected)
            collected = reinit(collected)
            prevpush = time()
        end
        for root in allroots(input)
            add_action!(output, root) do output
                collected = f(collected,  value(input))
                elapsed = time() - prevpush
                close(timer)
                if elapsed > dt
                    dopush(elapsed)
                else
                    timer = Timer(dopush, dt-elapsed)
                end
            end
        end
    end
end

"""
    every(dt)

A signal that updates every `dt` seconds to the current timestamp. Consider using `fpswhen` or `fps` before using `every`.
"""
function every(dt; name=auto_name!("every $dt secs"))
    n = Signal(time(), (); name=name)
    every_connect(dt, n)
    n
end

function every_connect(dt, output)
    outputref = WeakRef(output)
    timer = Timer(x -> push!(outputref.value, time(), ()->close(timer)), dt, dt)
    finalizer(output, _->close(timer))
    output
end

"""
    fpswhen(switch, rate)

returns a signal which when `switch` signal is true, updates `rate` times every second. If `rate` is not possible to attain because of slowness in computing dependent signal values, the signal will self adjust to provide the best possible rate.
"""
function fpswhen(switch, rate; name=auto_name!("$rate fpswhen", switch))
    # Creates a node and sets up a timer that pushes to the node every 1.0/rate
    # seconds. Is slightly unusual in that it has a parent node (switch), but is
    # regarded as a root node, since downstream actions must be added to its
    # action queue so that they update whenever it does. When switch updates,
    # downstream actions don't need to run, they only need to run when this node
    # runs, thus they shouldn't be added to the action_queues of the switch, so
    # we set the nodes roots to (). Only the action that organises the next tick
    # (see fpswhen_connect) needs to be in the action_queues that the
    # switch is in.
    n = Signal(Float64, 0.0, (switch,); name=name)
    action_queues[n] = []
    n.roots = ()
    root_nodes[n] = nothing
    fpswhen_connect(rate, switch, n)
    n
end

function setup_next_tick(outputref, switchref, dt, wait_dt)
    if value(switchref.value)
        Timer(t -> begin
            if value(switchref.value)
                push!(outputref.value, dt)
            end
       end, wait_dt)
    end
end

function fpswhen_connect(rate, switch, output)
    let prev_time = time()
        dt = 1.0/rate
        outputref = WeakRef(output)
        switchref = WeakRef(switch)
        for node in (allroots(switch)..., output)
            add_action!(output, node) do output
                start_time = time()
                setup_next_tick(outputref, switchref, start_time-prev_time, dt)
                prev_time = start_time
            end
        end
        setup_next_tick(outputref, switchref, dt, dt)
    end
end

"""
    fps(rate)

Same as `fpswhen(Input(true), rate)`
"""
fps(rate; name="$rate fps") = fpswhen(Signal(Bool, true, (); name="fps true"), rate; name=name)
