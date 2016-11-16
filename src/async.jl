
export remote_map,
       async_map

"""
    tasks, results = async_map(f, init, input...;typ=typeof(init), onerror=Reactive.print_error)
Spawn a new task to run a function when input signal updates. Returns a signal of tasks and a `results` signal which updates asynchronously with the results. `init` will be used as the default value of `results`. `onerror` is the callback to be called when an error occurs, by default it is set to a callback which prints the error to STDERR. It's the same as the `onerror` argument to `push!` but is run in the spawned task.
"""
function async_map(f, init, inputs...; typ=typeof(init), onerror=print_error)

    node = Signal(typ, init, inputs)
    action_queues[node] = []
    map(inputs...; init=nothing, typ=Any) do args...
        outer_task = current_task()
        @async begin
            try
                x = f(args...)
                push!(node, x, onerror)
            catch err
                Base.throwto(outer_task, CapturedException(err, catch_backtrace()))
            end
        end
    end, node
end

"""
    remoterefs, results = remote_map(procid, f, init, input...;typ=typeof(init), onerror=Reactive.print_error)

Spawn a new task on process `procid` to run a function when input signal updates. Returns a signal of remote refs and a `results` signal which updates asynchronously with the results. `init` will be used as the default value of `results`. `onerror` is the callback to be called when an error occurs, by default it is set to a callback which prints the error to STDERR. It's the same as the `onerror` argument to `push!` but is run in the spawned task.
"""
function remote_map(procid, f, init, inputs...; typ=typeof(init), onerror=print_error)

    node = Signal(typ, init, inputs)

    node = Signal(typ, init, inputs)
    map(inputs...; init=nothing, typ=Any) do args...
        outer_task = current_task()
        rref = @spawnat procid begin
            f(args...)
        end
        @async begin
            try
                x = fetch(rref)
                push!(node, x, onerror)
            catch err
                Base.throwto(outer_task, CapturedException(err, catch_backtrace()))
            end
        end
    end, node
end

