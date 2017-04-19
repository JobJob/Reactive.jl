import Base: map, merge, filter, ==, hash

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

#need these for `findin` to work...
"""
Probably shouldn't be equal if `a.recipient.value` has been garbage collected
and is thus nothing, as they may have once been different actions. In truth
though they almost definitely are the same since each function/action is only
ever associated with one node at time of writing. This might change though, so
play it safe.
"""
==(a::Action, b::Action) = a === b ||
(a.f === b.f &&
a.recipient.value != nothing &&
b.recipient.value != nothing &&
a.recipient.value === b.recipient.value)

"""
Hash should be based on objectid if `a.recipient.value` is `nothing` to match
`==(::Action, ::Action)`
"""
function hash(a::Action, h::UInt)
    a.recipient.value == nothing && return 3*objectid(a) - h
    hash(a.recipient, h) + hash(a.f, h)
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


"""
`connect_flatten(output, input)`
`output` is the flatten node, `input` is the Signal{Signal} ("sigsig") node
Descendents of this flatten node need to know to update on changes to
the input sigsig (allroots(input)), or changes to the value of the
current sig (roots == allroots(current_node))
"""
function connect_flatten(output, input)
    let current_node = value(input)
        # current_node is the signal/node that is the sigsig's current value
        # wire_current_node ensures the flatten and its descendents update when
        # the value of the sigsig's current signal changes
        set_flatten_val(flatten_node) = send_value!(flatten_node, value(current_node))
        wire_current_node(current_node, subtree_actions::Vector{Action}) = begin
            roots = allroots(current_node)
            # @show "wire_current_node" output current_node
            for root in roots
                # ensure flatten node updates when current_node gets pushed a new value
                add_action!(set_flatten_val, output, root)
                # ensure nodes in the subtree rooted at the flatten node update
                # too when the flatten node's value changes.
                # If the subtree node is already in queue, remove it and re-add
                # it so it appears after the flatten node, this will ensure those
                # downstream nodes will use the updated value of the flatten.
                # XXX I think that's mostly correct but possibly not 100%
                queue = action_queues[root]
                # @show root queue subtree_actions "-------"
                deleteat!(queue, findin(queue, subtree_actions))
                append!(queue, subtree_actions)
            end
            output.roots = (OrderedSet((allroots(input)..., roots...))...)
        end
        # On creation the flatten node has no downstream actions, hence the empty Action[]
        wire_current_node(current_node, Action[])
        # create an action to update the flatten when the sigsig gets a new
        # signal as its value. Add this action to all the action_queues that have
        # the sigsig in it, so that the flatten and its descendents will update
        # when this occurs.
        for inp_root in allroots(input)
            update_flatten(output) = begin
                # remove all descendents from action queues of the (soon to be)
                # previous signal (current_node) so they won't update anymore
                # when the prev signal updates

                # get all downstream actions from the output/flatten node
                subtree_actions = queue_subtree_actions(output; queue_root=current_node)
                for oldroot in allroots(current_node)
                    for action in subtree_actions
                        node = action.recipient.value
                        # subtlety: if the descendent `node` is also connected
                        # to the oldroot via another path (i.e. not via this
                        # flatten), it should still remain in the oldroot's
                        # action_queue. So we don't remove nodes from oldroot's
                        # action_queue whose roots, ignoring paths through the
                        # flatten node (output), contain oldroot.
                        oldroot in roots_without(node, output) && continue
                        remove_actions!(node, oldroot)
                    end
                end
                current_node = value(input)
                send_value!(output, value(current_node))
                wire_current_node(current_node, subtree_actions)
            end
            add_action!(update_flatten, output, inp_root)
        end
    end
end

"""
`queue_subtree_actions(basenode)`
Get all actions that are descendent/"downstream" from basenode, i.e. all actions
that should be triggered if basenode's value updates. Also includes the root of
the subtree, i.e. the first action with basenode as a recipient
"""
function queue_subtree_actions(basenode; queue_root=first(allroots(basenode)))
    # basenode_action_idxs = find(action->action.recipient.value == basenode, queue)
    # isempty(basenode_action_idxs) && return basenode_action_idxs
    queue = action_queues[queue_root]
    isempty(queue) && return queue

    @show "queue_subtree_actions" basenode queue_root queue _bindings
    # If basenode_action_idxs is empty, then this is the special case of
    # bind!ing to an input node...
    baseidx = isroot(basenode)? 1 :
                find(action->action.recipient.value == basenode, queue) |> first

    # @show baseidx
    subtree_nodes = Signal[basenode]
    subtree_actions = Action[queue[baseidx]]
    #go through actions in queue starting at subnode
    for actionidx in baseidx+1:length(queue)
        action = queue[actionidx]
        node = action.recipient.value
        if any(map(node.parents) do node;
                node in subtree_nodes ||
                any(haskey(_bindings, src => node) for src in subtree_nodes)
            end)
            #node has parents that are in the sub-tree
            push!(subtree_nodes, node)
            push!(subtree_actions, action)
        end
    end
    @show subtree_actions "--------"
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
    # add roots of src to dest's roots to ensure that new nodes descendent from
    # dest will update when src updates.
    dest.roots = allroots(src)
    # add src as a parent so dest will have an active parent when src updates
    # and the copy_to_dest action (and in-turn other downstream actions) will run
    dest.parents = (dest.parents..., src)
    local action #will be bound to the last action but they're all identical
    copy_to_dest(dest) = begin
        @show "copy_to_dest" dest src value(src)
        send_value!(dest, value(src))
    end
    subtree_actions = queue_subtree_actions(dest)
    # add copy_to_dest to the action_queues of all roots of src to ensure
    # the dest node is updated whenever src updates
    for root in allroots(src)
        root == dest && continue
        action = add_action!(copy_to_dest, dest, root)
        # remove and re-append dest's descendent actions to the root's
        # action_queue, so that actions "downstream" from dest will run when
        # dest updates as a result of the src updating.
        queue = action_queues[root]
        @show dest src twoway root queue subtree_actions
        deleteat!(queue, findin(queue, subtree_actions))
        append!(queue, subtree_actions)
        @show queue "-------"
    end
    _bindings[src=>dest] = action

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
