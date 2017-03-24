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
       unbind!

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
    let
        add_action!(output) do output
            send_value!(output, f(map(value, inputs)...))
        end
    end
end

probe(node, name, io=STDERR) =
    map(x -> println(io, name, " >! ", x), node)

"""
    foreach(f, inputs...)

Same as `map`, but will be prevented from gc until all the inputs have gone out of scope. Should be used in cases where `f` does a side-effect.
"""
foreach(f, inputs::Signal...; kwargs...) = preserve(map(f, inputs...; kwargs...))

"""
    filter(f, signal)

remove updates from the signal where `f` returns `false`.
"""
function filter{T}(f::Function, default, input::Signal{T}; name=auto_name!("filter", input))
    n = Signal(T, f(value(input)) ? value(input) : default, (input,); name=name)
    connect_filter(f, default, n, input)
    n
end

function connect_filter(f, default, output, input)
    add_action!(output) do output
        val = value(input)
        if f(val)
            send_value!(output, val)
        else
            output.active = false
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
    add_action!(output) do output
        if value(predicate)
            output.active = true
            send_value!(output, value(input))
        else
            output.active = false
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
    let acc = v0
        add_action!(output) do output
            vals = map(value, inputs)
            acc = f(acc, vals...)
            send_value!(output, acc)
        end
    end
end

"""
    sampleon(a, b)

Sample the value of `b` whenever `a` updates.
"""
function sampleon{T}(sampler, input::Signal{T}; name=auto_name!("sampleon", input))
    n = Signal(T, value(input), (sampler, input); name=name)
    connect_sampleon(n, sampler, input)
    n
end

function connect_sampleon(output, sampler, input)
    add_action!(output, sampler) do output
        send_value!(output, value(input))
    end
end


"""
    merge(input...)

Merge many signals into one. Returns a signal which updates when
any of the inputs update. If many signals update at the same time,
the value of the *youngest* input signal is taken.
"""
function merge(inputs...; name=auto_name!("merge", inputs...))
    @assert length(inputs) >= 1
    n = Signal(typejoin(map(eltype, inputs)...), value(inputs[1]), inputs; name=name)
    connect_merge(n, inputs...)
    n
end

function connect_merge(output, inputs...)
    let
        for root in output.roots
            add_action!(output, root) do output
                lastactive = getlastactive(root, output)
                send_value!(output, value(lastactive))
            end
        end
    end
end

"""
search in action_queues[root] for node.parents
"""
function getlastactive(root, node)
    actionq = action_queues[root]
    i = length(actionq)
    lastactive = last(node.parents) # defaults to last signal parent
    while i > 0
        action_node = actionq[i].recipient.value
        if action_node.active && action_node in node.parents
            lastactive = action_node
            break
        end
        i -= 1
    end
    lastactive
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
    let prev_value = value(input)
        add_action!(output) do output
            send_value!(output, prev_value)
            prev_value = value(input)
        end
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
    #n gets pushed to so has to be the root of an action_queue
    n.roots = ()
    action_queues[n] = []
    connect_delay(n, input)
    n
end

function connect_delay(output, input)
    add_action!(output, input) do output
        push!(output, value(input))
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
    let prev_value = value(input)
        add_action!(output) do output
            if prev_value != value(input)
                send_value!(output, value(input))
                prev_value = value(input)
            else
                output.active = false
            end
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
    n = Signal(typ, value(value(input)), (input,); name=name)
    connect_flatten(n, input)
    n
end

function connect_flatten(output, input)
    let current_node = value(input)
        wire_flatten(current_node, subtree_actions::Vector{Action}) = begin
            #children of this flatten node need to know to update
            #on changes to the input sigsig (allroots(input)),
            #or changes to the value of the current sig (roots == allroots(current_node))
            # @show "switched to " current_node
            roots = allroots(current_node)
            for root in roots
                #ensure updates when current_node gets pushed a new value
                add_action!(output, root) do output
                    send_value!(output, value(current_node))
                end
                #ensure updates for subtree too, if action is already in queue
                #remove it and readd it so it's deeper down. XXX I think that's
                #mostly correct but prob not 100%
                queue = action_queues[root]
                for action in subtree_actions
                    deleteat!(queue, findin(queue, 6))
                end
                append!(queue, subtree_actions)
            end
            output.roots = (OrderedSet((allroots(input)..., roots...))...)
        end
        wire_flatten(current_node, Action[])
        inp_roots = allroots(input)
        for inp_root in inp_roots
            add_action!(output, inp_root) do output
                #input gets pushed a new signal
                #remove all children from action queues of prev signal
                oldroots = allroots(current_node)
                subtree_actions = Action[]
                for deadroot in oldroots
                    subtree_actions = queue_subtree_actions(action_queues[deadroot], output)
                    for action in subtree_actions
                        #subtlety: iff the sub-node is also connected
                        #to the deadroot via another path (i.e. not via this flatten)
                        #it will be incorrectly removed from that action tree.
                        #so we must ignore nodes whose ancestors without this node
                        #contain deadroot
                        node = action.recipient.value
                        deadroot in roots_without(node, output) && continue
                        remove_actions!(node, deadroot)
                    end
                end
                current_node = value(input)
                send_value!(output, value(current_node))
                wire_flatten(current_node, subtree_actions)
            end
        end
    end
end

queue_subtree_actions(queue, basenode) = begin
    baseidx = find(action->action.recipient.value == basenode, queue) |> first
    subtree_nodes = Any[basenode]
    subtree_actions = Action[queue[baseidx]]
    for actionidx in baseidx:length(queue)
        action = queue[actionidx]
        node = action.recipient.value
        if any(map(node.parents) do node; node in subtree_nodes end)
            #node has parents that are in the sub-tree
            push!(subtree_nodes, node)
            push!(subtree_actions, action)
        end
    end
    subtree_actions
end

"""
find roots in paths not through ignorenode
"""
roots_without(startnode, ignorenode; roots = Dict{Signal, Bool}()) = begin
    goodparents = filter(startnode.parents) do parent; parent != ignorenode end
    for parent in goodparents
        if isempty(parent.parents)
            roots[parent] = true
        else
            roots_without(parent, ignorenode; roots=roots)
        end
    end
    keys(roots)
end

const _bindings = Dict()

"""
    bind!(a,b,twoway=true)

for every update to `a` also update `b` with the same value and vice-versa.
To only bind updates from b to a, pass in a third argument as `false`
"""
function bind!(a::Signal, b::Signal, twoway=true)

    let
        action = add_action!(a) do a
            send_value!(b, value(a))
        end
        _bindings[a=>b] = action
    end

    if twoway
        bind!(b, a, false)
    end
end

"""
    unbind!(a,b,twoway=true)

remove a link set up using `bind!`
"""
function unbind!(a::Signal, b::Signal, twoway=true)
    if !haskey(_bindings, a=>b)
        return
    end

    action = _bindings[a=>b]
    remove_action!(a, action)
    delete!(_bindings, a=>b)

    if twoway
        unbind!(b, a, false)
    end
end
