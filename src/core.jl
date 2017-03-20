import Base: push!, eltype, close
export Signal, push!, value, preserve, unpreserve, close, rename!

using DataStructures

using DataStructures

##### Signal #####

const debug_memory = false # Set this to true to debug gc of nodes

const nodes = WeakKeyDict()
const io_lock = ReentrantLock()

if !debug_memory
    type Signal{T}
        value::T
        parents::Tuple
        roots::Tuple
        actions::Vector
        alive::Bool
        preservers::Dict
        name::String
        function Signal(v, parents, actions, alive, pres, name)
            roots = getroots(parents)
            n=new(v,parents,roots,actions,alive,pres,name)
            isempty(roots) && (action_queues[n] = [])
            n
        end
    end
else
    type Signal{T}
        value::T
        parents::Tuple
        roots::Tuple
        actions::Vector
        alive::Bool
        preservers::Dict
        name::String
        bt
        function Signal(v, parents, actions, alive, pres, name)
            roots = getroots(parents)
            n=new(v,parents,roots,actions,alive,pres,name,backtrace())
            isempty(roots) && (action_queues[n] = [])
            nodes[n] = nothing
            finalizer(n, log_gc)
            n
        end
    end
end

allroots(maybe_root_node) =
    isempty(maybe_root_node.roots) ? [maybe_root_node] : maybe_root_node.roots

function getroots(parents)
    roots = Dict{Signal, Bool}()
    for parent in parents
        for root in allroots(parent)
            roots[root] = true
        end
    end
    return (keys(roots)...)
end


log_gc(n) =
    @async begin
        lock(io_lock)
        print(STDERR, "Signal got gc'd. Creation backtrace:")
        Base.show_backtrace(STDERR, n.bt)
        println(STDOUT)
        unlock(io_lock)
    end

immutable Action
    recipient::WeakRef
    f::Function
end

const node_count = DefaultDict{String,Int}(0) #counts of different signals for naming
function auto_name!(name, parents...)
    parents_str = join(map(s->s.name, parents), ", ")
    isempty(parents_str) || (name *= "($parents_str)")
    node_count[name] += 1
    countstr = node_count[name] > 1 ? "-$(node_count[name])" : ""
    "$name$countstr"
end

"""
`rename!(s::Signal, name::String)`

Change a Signal's name
"""
function rename!(s::Signal, name::String)
    s.name = name
end

const action_queue = Queue(Tuple{Signal, Action})

isrequired(a::Action) = (a.recipient.value != nothing) && a.recipient.value.alive

Signal{T}(x::T, parents=(); name::String=auto_name!("input")) = Signal{T}(x, parents, Action[], true, Dict{Signal, Int}(), name)
Signal{T}(::Type{T}, x, parents=(); name::String=auto_name!("input")) = Signal{T}(x, parents, Action[], true, Dict{Signal, Int}(), name)
# A signal of types
Signal(t::Type; name::String = auto_name!("input")) = Signal(Type, t, name)

#In general, one action per node makes sense now, I think
#so you just add the recipient to the queue and not the Action.
nodes_in_queue(nodes, queue) = filter(n->n in nodes)

isrequired(a::Action, processed_nodes::Dict{Signal, Bool}) = begin
    node = a.recipient.value
    haskey(processed_nodes,node) && node.alive && return true #needed for fps node timers
    any(map(n->haskey(processed_nodes, n)||haskey(processed_nodes, value(n)) #value(n) is for flatten
            , node.parents)) &&
        node != nothing &&
        node.alive
end

const action_queues = Dict{Signal, Vector{Action}}()

# preserve/unpreserve nodes from gc
"""
    preserve(signal::Signal)

prevents `signal` from being garbage collected as long as any of its parents are around. Useful for when you want to do some side effects in a signal.
e.g. `preserve(map(println, x))` - this will continue to print updates to x, until x goes out of scope. `foreach` is a shorthand for `map` with `preserve`.
"""
function preserve(x::Signal)
    for p in x.parents
        p.preservers[x] = get(p.preservers, x, 0)+1
        preserve(p)
    end
    x
end

"""
    unpreserve(signal::Signal)

allow `signal` to be garbage collected. See also `preserve`.
"""
function unpreserve(x::Signal)
    for p in x.parents
        n = get(p.preservers, x, 0)-1
        if n <= 0
            delete!(p.preservers, x)
        else
            p.preservers[x] = n
        end
        unpreserve(p)
    end
    x
end

Base.show(io::IO, n::Signal) =
    write(io, "$(n.name): Signal{$(eltype(n))}($(n.value), nactions=$(length(n.actions))$(n.alive ? "" : ", closed"))")

value(n::Signal) = n.value
value(::Void) = false
eltype{T}(::Signal{T}) = T
eltype{T}(::Type{Signal{T}}) = T

##### Connections #####

function add_action!(f, recipient, root=nothing)
    a = Action(WeakRef(recipient), f)
    roots = root == nothing ? recipient.roots : [root]
    for aroot in roots #empty for inputs to graph, i.e. nodes that are push!ed to, including time nodes like fps
        push!(action_queues[aroot], a)
        # action_queue_nodes[a.recipient] = true
    end
    a
end

function remove_actions!(recipient, root=nothing)
    roots = root == nothing ? recipient.roots : [root]
    for root in roots
        filter!(action_queues[root]) do action
            action.recipient.value != recipient
        end
    end
    nothing
end

function close(n::Signal, warn_nonleaf=true)
    #XXX: make this work
    finalize(n) # stop timer etc.
    n.alive = false
    if !isempty(n.actions)
        any(map(isrequired, n.actions)) && warn_nonleaf &&
            warn("closing a non-leaf node is not a good idea")
        empty!(n.actions)
    end

    for p in n.parents
        delete!(p.preservers, n)
    end
end

function send_value!(node::Signal, x, timestep)
    # Dead node?
    !node.alive && return

    # Set the value and do actions
    node.value = x
    # for action in node.actions
    #     do_action(action, timestep)
    # end
end
send_value!(wr::WeakRef, x, timestep) = wr.value != nothing && send_value!(wr.value, x, timestep)

do_action(a::Action, timestep, processed_nodes::Dict{Signal, Bool}) = begin
    if isrequired(a, processed_nodes)
        a.f(a.recipient.value, timestep)
    else
        a.recipient.value.alive = false
    end
end
# If any actions have been gc'd, remove them
cleanup_actions(node::Signal) =
    node.actions = filter(isrequired, node.actions)


##### Messaging #####

const CHANNEL_SIZE = 1024

immutable Message
    node
    value
    onerror::Function
end

# Global channel for signal updates
const _messages = Channel{Nullable{Message}}(CHANNEL_SIZE)


"""
`push!(signal, value, onerror=Reactive.print_error)`

Queue an update to a signal. The update will be propagated when all currently
queued updates are done processing.

The third optional argument is a callback to be called in case the update
ends in an error. The callback receives 3 arguments: the signal, the value,
and a `CapturedException` with the fields `ex` which is the rootal exception
object, and `processed_bt` which is the backtrace of the exception.

The default error callback will print the error and backtrace to STDERR.
"""
Base.push!(n::Signal, x, onerror=print_error) = _push!(n, x, onerror)

function _push!(n, x, onerror=print_error)
    taken = Base.n_avail(_messages)
    if taken >= CHANNEL_SIZE
        warn("Message queue is full. Ordering may be incorrect.")
        @async put!(_messages, Message(n, x, onerror))
    else
        put!(_messages, Message(n, x, onerror))
    end
    nothing
end
_push!(::Void, x, onerror=print_error) = nothing


const timestep = Ref{Int}(0)

function break_loop()
    put!(_messages, Nullable{Message}())
end

function stop()
    run_till_now() # process all remaining events
    break_loop()
end

Base.shift!(od::OrderedDict) = begin
    firstkey = od |> keys |> first
    res = od[firstkey]; delete!(od, firstkey)
    firstkey=>res
end

"""
Processes `n` messages from the Reactive event queue.
"""
function run(n::Int=typemax(Int))
    processed_nodes = Dict{Signal, Bool}()
    ts = timestep[]
    for i=1:n
        ts += 1
        message = take!(_messages)
        isnull(message) && break # ignore emtpy messages

        msgval = get(message)
        node = msgval.node
        try
            send_value!(msgval.node, msgval.value, ts)
            # @show "-----------" msgval.node.value
            empty!(processed_nodes)
            processed_nodes[msgval.node] = true
            for action in action_queues[msgval.node]
                node = action.recipient.value
                # @show node node.parents processed_nodes
                do_action(action, ts, processed_nodes)
                # @show node.alive
                node.alive && (processed_nodes[node] = true)
            end
            foreach(action_queues[msgval.node]) do action
                action.recipient.value.alive = true
            end
        catch err
            if isa(err, InterruptException)
                println("Reactive event loop was inturrupted.")
                rethrow()
            else
                bt = catch_backtrace()
                msgval.onerror(msgval.node, msgval.value, node, CapturedException(err, bt))
            end
        finally
            timestep[] = ts
        end
    end
end

# Default error handler function
function print_error(node, value, error_node, ex)
    lock(io_lock)
    io = STDERR
    println(io, "Failed to push!")
    print(io, "    ")
    show(io, value)
    println(io)
    println(io, "to node")
    print(io, "    ")
    show(io, node)
    println(io)
    println(io)
    println(io, "error at node: $error_node")
    showerror(io, ex)
    println(io)
    unlock(io_lock)
end

# Run everything queued up till the instant of calling this function
run_till_now() = run(Base.n_avail(_messages))

# A decent default runner task
function __init__()
    global runner_task = @async begin
        Reactive.run()
    end
end
