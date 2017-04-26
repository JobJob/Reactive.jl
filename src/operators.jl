import Base: map, merge, filter

if isdefined(Base, :foreach)
    import Base.foreach
end

export map,
       probe,
       filter,
       filterwhen,
       foldp,
       sampleon,
       merge,
       previous,
       delay,
       droprepeats,
       flatten,
       bind!,
       unbind!,
       bound_srcs,
       bound_dests

"""
    map(f, s::Signal...) -> signal

Transform signal `s` by applying `f` to each element. For multiple signal arguments, apply `f` elementwise.
"""
function map(f, input::Signal, inputsrest::Signal...;
             init=f(map(value, (input,inputsrest...))...),
             typ=typeof(init), name=auto_name!("map", input, inputsrest...))

    n = Signal(typ, init, (input,inputsrest...); name=name)
    connect_map(f, n, input, inputsrest...)
    n
end

function connect_map(f, output, inputs...)
    add_action!(output) do
        set_value!(output, f(map(value, inputs)...))
    end
end

probe(node, name, io=STDERR) =
    map(x -> println(io, name, " >! ", x), node)

"""
    foreach(f, inputs...)

Same as `map`, but will be prevented from gc until all the inputs have gone out of scope. Should be used in cases where `f` does a side-effect.
"""
foreach(f, in1::Signal, inputs::Signal...; kwargs...) = preserve(map(f, in1, inputs...; kwargs...))

"""
    filter(f, default, signal)

remove updates from the `signal` where `f` returns `false`. The filter will hold
the value default until f(value(signal)) returns true, when it will be updated
to value(signal).
"""
function filter{T}(f::Function, default, input::Signal{T}; name=auto_name!("filter", input))
    n = Signal(T, f(value(input)) ? value(input) : default, (input,); name=name)
    connect_filter(f, default, n, input)
    n
end

function connect_filter(f, default, output, input)
    add_action!(output) do
        val = value(input)
        if f(val)
            set_value!(output, val)
        else
            deactivate!(output)
        end
    end
end

"""
    filterwhen(switch::Signal{Bool}, default, input)

Keep updates to `input` only when `switch` is true.

If switch is false initially, the specified default value is used.
"""
function filterwhen{T}(predicate::Signal{Bool}, default, input::Signal{T};
                        name=auto_name!("filterwhen", predicate, input))
    n = Signal(T, value(predicate) ? value(input) : default, (input,); name=name)
    connect_filterwhen(n, predicate, input)
    n
end

function connect_filterwhen(output, predicate, input)
    add_action!(output) do
        if value(predicate)
            set_value!(output, value(input))
        else
            deactivate!(output)
        end
    end
end

"""
    foldp(f, init, input)

[Fold](http://en.wikipedia.org/wiki/Fold_(higher-order_function)) over past values.

Accumulate a value as the `input` signal changes. `init` is the initial value of the accumulator.
`f` should take 2 arguments: the current accumulated value and the current update, and result in the next accumulated value.
"""
function foldp(f::Function, v0, inputs...; typ=typeof(v0), name=auto_name!("foldp", inputs...))
    n = Signal(typ, v0, inputs; name=name)
    connect_foldp(f, v0, n, inputs)
    n
end

function connect_foldp(f, v0, output, inputs)
    acc = v0
    add_action!(output) do
        vals = map(value, inputs)
        acc = f(acc, vals...)
        set_value!(output, acc)
    end
end

"""
    sampleon(a, b)

Sample the value of `b` whenever `a` updates.
"""
function sampleon{T}(sample_trigger, input::Signal{T}; name=auto_name!("sampleon", input))
    n = Signal(T, value(input), (sample_trigger,); name=name)
    connect_sampleon(n, input)
    n
end

function connect_sampleon(output, input)
    # this will only get run when sampler updates, as sample_trigger is output's only
    # parent, see isrequired
    add_action!(output) do
        set_value!(output, input.value)
    end
end


"""
    merge(inputs...)

Merge many signals into one. Returns a signal which updates when
any of the inputs update. If many signals update at the same time,
the value of the *youngest* (most recently created) input signal is taken.
"""
function merge(in1::Signal, inputs::Signal...; name=auto_name!("merge", in1, inputs...))
    n = Signal(typejoin(map(eltype, (in1, inputs...))...), value(in1), (in1, inputs...); name=name)
    connect_merge(n, in1, inputs...)
    n
end

function connect_merge(output, inputs...)
    add_action!(output) do
        lastactive = getlastactive(output)
        lastactive != nothing && set_value!(output, value(lastactive))
        # we don't deactivate! on lastactive == nothing, since I suppose the push
        # should propagate even if some of the nodes died just after updating.
    end
end

"""
`getlastactive(merge_node)`
Search backwards in nodes, and return the first active node that is one
of merge_node's parents
"""
function getlastactive(merge_node)
    i = merge_node.id - 1
    while i > 0
        node = nodes[i].value
        if isactive(node) && node in merge_node.parents
            return node
        end
        i -= 1
    end
    # If parent nodes have all been GC'd, but there is still a reference to the
    # merge in user code, then none of the parents should have been active,
    # so the merge action shouldn't run, so we shouldn't have got here. However,
    # in the rare case that the node got GC'd after it was found to be an active
    # parent of the merge but before we got here, then I guess the merge node
    # shouldn't change value.
    return nothing
end

"""
    previous(input, default=value(input))

Create a signal which holds the previous value of `input`.
You can optionally specify a different initial value.
"""
function previous{T}(input::Signal{T}, default=value(input); name=auto_name!("previous", input))
    n = Signal(T, default, (input,); name=name)
    connect_previous(n, input)
    n
end

function connect_previous(output, input)
    prev_value = value(input)
    add_action!(output) do
        set_value!(output, prev_value)
        prev_value = value(input)
    end
end

"""
    delay(input, default=value(input))

Schedule an update to happen after the current update propagates
throughout the signal graph.

Returns the delayed signal.
"""
function delay{T}(input::Signal{T}, default=value(input); name=auto_name!("delay", input))
    n = Signal(T, default, (input,); name=name)
    connect_delay(n, input)
    n
end

function connect_delay(output, input)
    add_action!(output) do
        # only push when input is active (avoids it pushing to itself endlessly)
        isactive(input) && push!(output, value(input))
    end
end

"""
    droprepeats(input)

Drop updates to `input` whenever the new value is the same
as the previous value of the signal.
"""
function droprepeats{T}(input::Signal{T}; name=auto_name!("droprepeats", input))
    n = Signal(T, value(input), (input,); name=name)
    connect_droprepeats(n, input)
    n
end

function connect_droprepeats(output, input)
    prev_value = value(input)
    add_action!(output) do
        if prev_value != value(input)
            set_value!(output, value(input))
            prev_value = value(input)
        else
            deactivate!(output)
        end
    end
end

"""
    flatten(input::Signal{Signal}; typ=Any)

Flatten a signal of signals into a signal which holds the
value of the current signal. The `typ` keyword argument specifies
the type of the flattened signal. It is `Any` by default.
"""
function flatten(input::Signal; typ=Any, name=auto_name!("flatten", input))
    n = Signal(typ, input.value.value, (input,); name=name)
    connect_flatten(n, input)
    n
end


"""
`connect_flatten(output, input)`
`output` is the flatten node, `input` is the Signal{Signal} ("sigsig") node
Descendents of this flatten node need to know to update on changes to
the input sigsig (allroots(input)), or changes to the value of the
current sig (roots == allroots(current_node))
"""
function connect_flatten(output, input)
    # input is a Signal{Signal} (aka sigsig)
    # current_node is the signal/node that is the sigsig's current value.
    # wire_flatten sets the flatten's parents when the sigsig gets a new
    # signal as its value. This ensures the flatten output node's value will
    # update when either the current_node updates, or when the input sigsig
    # updates.
    current_node = input.value
    wire_flatten() = begin
        # remove previous signal (current_node) from output's parents so
        # it won't update anymore when the prev signal updates
        prev_node = current_node
        orig_parents = filter(n->n != prev_node, output.parents)
        current_node = input.value
        output.parents = (orig_parents..., current_node)
    end

    # set_flatten_val updates the flatten node.
    # Both actions will be run when current_node
    # gets pushed a new value or when the input gets pushed a new signal (since
    # both are parents of the flatten)
    set_flatten_val() = set_value!(output, current_node.value)
    add_action!(wire_flatten, output)
    add_action!(set_flatten_val, output)
    wire_flatten()
end

const _bindings = Dict() # XXX GC Issue? can't use WeakKeyDict with Pairs...
const _active_binds = Dict()

"""
Pause a push by recording the active nodes and setting them to inactive.
The push can be resumed by reactivating the nodes.
"""
function pause_push()
    active_nodes = WeakRef[]
    for noderef in nodes
        node = noderef.value
        if isactive(node)
            push!(active_nodes, WeakRef(node))
            deactivate!(node)
        end
    end
    active_nodes
end

"""
    `bind!(dest, src, twoway=true)`

for every update to `src` also update `dest` with the same value and, if
`twoway` is true, vice-versa.
"""
function bind!(dest::Signal, src::Signal, twoway=true)
    if haskey(_bindings, src=>dest)
        # subsequent bind!(dest, src) after initial should be a no-op
        # though we should allow a change in preference for twoway bind.
        if twoway
            bind!(src, dest, false)
        end
        return
    end

    # We don't set src as a parent of dest, since a
    # two-way bind would technically introduce a cycle into the signal graph,
    # and I suppose we'd prefer not to have that. Instead we just set dest as
    # active when src updates, which will allow its downstream actions to run.

    bind_updater =
        if dest.id < src.id
            # src comes after dest, so dest's downstream actions won't run
            # unless we arrange it.
            twoway && (_active_binds[dest=>src] = false) # pair is ordered by id
            function bind_updater_src_post()
                is_twoway = haskey(_active_binds, dest=>src)
                println("bind_updater_src_post")
                @show is_twoway _active_binds[dest=>src]
                if is_twoway && _active_binds[dest=>src]
                    # The _active_binds flag stops the (infinite) cycle of src
                    # updating dest updating src ... in the case of a two-way bind
                    _active_binds[dest=>src] = false
                else
                    is_twoway && (_active_binds[dest=>src] = true)
                    # we "pause" the current push!, simulate a push! to dest with
                    # run_push then resume processing the original push by reactivating
                    # the previously active nodes.
                    active_nodes = pause_push()
                    @show active_nodes
                    run_push(dest, src.value, onerror_rethrow)
                    foreach(activate!, active_nodes)
                end
            end
        else
            twoway && (_active_binds[src=>dest] = false) # pair is ordered by id
            function bind_updater_src_pre()
                is_twoway = haskey(_active_binds, src=>dest)
                println("bind_updater_src_pre")
                @show is_twoway _active_binds[src=>dest]
                if is_twoway && _active_binds[src=>dest]
                    _active_binds[src=>dest] = false
                else
                    is_twoway && (_active_binds[src=>dest] = true)
                    set_value!(dest, src.value)
                    activate!(dest) # set dest as active so dest's downstream actions will run
                end
            end
        end
    action = add_action!(bind_updater, src)
    finalizer(src, (src)->unbind!(dest, src, twoway))

    _bindings[src=>dest] = action

    # set dest to src's value on creation. TODO check this matches old behaviour.
    bind_updater()

    if twoway
        bind!(src, dest, false)
    end

end

"""
    `unbind!(dest, src, twoway=true)`

remove a link set up using `bind!`
"""
function unbind!(dest::Signal, src::Signal, twoway=true)
    if !haskey(_bindings, src=>dest)
        return
    end

    action = _bindings[src=>dest]
    remove_action!(src, action)
    delete!(_bindings, src=>dest)

    pair = src.id < dest.id ? src=>dest : dest=>src
    haskey(_active_binds, pair) && delete!(_active_binds, pair)

    if twoway
        unbind!(src, dest, false)
    end
end

"""
`bound_dests(src::Signal)` returns a vector of all signals that will update when
`src` updates, that were bound using `bind!(dest, src)`
"""
bound_dests(s::Signal) = [dest for (src, dest) in keys(_bindings) if src == s]

"""
`bound_srcs(dest::Signal)` returns a vector of all signals that will cause
an update to `dest` when they update, that were bound using `bind!(dest, src)`
"""
bound_srcs(s::Signal) = [src for (src, dest) in keys(_bindings) if dest == s]
