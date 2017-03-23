import Base: push!, eltype, close
export Signal, push!, value, preserve, unpreserve, close, rename!, run_async

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
        active::Bool
        alive::Bool
        preservers::Dict
        name::String
        function Signal(v, parents, actions, alive, pres, name)
            roots = getroots(parents)
            n=new(v, parents, roots, actions, false, alive, pres, name)
            isempty(roots) && (action_queues[n] = []) #root node
            finalizer(n, remove_actions!)
            n
        end
    end
else
    type Signal{T}
        value::T
        parents::Tuple
        roots::Tuple
        actions::Vector
        active::Bool
        alive::Bool
        preservers::Dict
        name::String
        bt
        function Signal(v, parents, actions, alive, pres, name)
            roots = getroots(parents)
            n=new(v,parents,roots,actions,false,alive,pres,name,backtrace())
            isempty(roots) && (action_queues[n] = []) #root node
            nodes[n] = nothing
            finalizer(n, log_gc)
            n
        end
    end
end

"""
Nodes are roots if they have an empty `node.roots`. We choose to set it as
empty, rather than having `node.roots == (node,)` to avoid an unecessary
self-reference - which would require working around problems with printing, saving
to disk etc. Instead, wherever we need the roots of a `node` to include the
root node itself we call `allroots(node)`.
"""
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

Signal{T}(x::T, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, Action[], true, Dict{Signal, Int}(), name)
Signal{T}(::Type{T}, x, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, Action[], true, Dict{Signal, Int}(), name)
# A signal of types
Signal(t::Type; name::String = auto_name!("input")) = Signal(Type, t, name)

#In general, one action per node makes sense now, I think
#so you just add the recipient to the queue and not the Action.
nodes_in_queue(nodes, queue) = filter(n->n in nodes)

isrequired(a::Action) = begin
    node = a.recipient.value
    if node == nothing || !node.alive
        info("isrequired($a) had a.recipient.value == nothing")
        return false #happens with gc sometimes
    end
    node.active && return true #needed for fps node timers
    for p in node.parents
        p.active && return true
        # for flatten nodes, their parent is a Signal{Signal}
        # their action isrequired if the parent is active (like other sigs: handled above)
        # or if the current Signal of the parent is active:
        (eltype(p) <: Signal) && value(p).active && return true
    end
    return false
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
    roots = root == nothing ? allroots(recipient) : [root]
    for aroot in roots
        push!(action_queues[aroot], a)
        # action_queue_nodes[a.recipient] = true
    end
    a
end

"""
Removes `action` from the action_queues of all roots of `node`
"""
function remove_action!(node, action, root=nothing)
    roots = root == nothing ? allroots(node) : [root]
    for root in roots
        filter!(action_queues[root]) do queue_action
            queue_action != action
        end
    end
    nothing
end

function remove_actions!(node, root=nothing)
    roots = root == nothing ? allroots(node) : [root]
    for root in roots
        filter!(action_queues[root]) do action
            action.recipient.value != node
        end
    end
    nothing
end

function close(n::Signal, warn_nonleaf=true)
    #XXX: make this work
    finalize(n) # stop timer etc.
    n.alive = false
    if !isempty(n.actions)
        # alarmist - see https://github.com/JuliaGizmos/Reactive.jl/issues/104
        # any(map(isrequired, n.actions)) && warn_nonleaf &&
        #     warn("closing a non-leaf node is not a good idea")
        empty!(n.actions)
    end

    for p in n.parents
        delete!(p.preservers, n)
    end
end

function send_value!(node::Signal, x, timestep)
    # Dead node?
    !node.alive && return
    node.value = x
end
send_value!(wr::WeakRef, x, timestep) = wr.value != nothing && send_value!(wr.value, x, timestep)

do_action(a::Action, timestep) = begin
    a.f(a.recipient.value, timestep)
end
# If any actions have been gc'd, remove them
cleanup_actions(node::Signal) =
    (node.actions = filter(isrequired, node.actions))


##### Messaging #####

const CHANNEL_SIZE = 1024

immutable Message
    node
    value
    onerror::Function
end

# Global channel for signal updates
const _messages = Channel{Nullable{Message}}(CHANNEL_SIZE)

#run in asynchronous mode by default
const async_mode = Ref(true)
run_async(async::Bool) = (async_mode[] = async)

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
@inline Base.push!(n::Signal, x, onerror=print_error) = begin
    if async_mode[]
        async_push!(n, x, onerror)
    else
        run_push(timestep[]+1, n, x, onerror)
    end
end

function async_push!(n, x, onerror=print_error)
    taken = Base.n_avail(_messages)
    if taken >= CHANNEL_SIZE
        warn("Message queue is full. Ordering may be incorrect.")
        @async put!(_messages, Message(n, x, onerror))
    else
        put!(_messages, Message(n, x, onerror))
    end
    nothing
end
async_push!(::Void, x, onerror=print_error) = nothing


const timestep = Ref{Int}(0)

function break_loop()
    put!(_messages, Nullable{Message}())
    yield()
end

function stop()
    run_till_now() # process all remaining events
    break_loop()
end

"""
Processes `n` messages from the Reactive event queue.
"""
function run(n::Int=typemax(Int))
    ts = timestep[]
    for i=1:n
        ts += 1
        message = take!(_messages)
        isnull(message) && break # ignore emtpy messages

        msgval = get(message)
        run_push(ts, msgval.node, msgval.value, msgval.onerror)
    end
end

function run_push(ts, rootnode, val, onerror)
    node = rootnode
    try
        send_value!(node, val, ts)
        node.active = true
        for action in action_queues[node]
            node = action.recipient.value
            if isrequired(action)
                action.recipient.value.active = true
                do_action(action, ts)
            else
                action.recipient.value.active = false
            end
        end
        node = rootnode
        #reset active status for actions
        foreach(action_queues[node]) do action
            action.recipient.value.active = false
        end
    catch err
        if isa(err, InterruptException)
            info("Reactive event loop was inturrupted.")
            rethrow()
        else
            bt = catch_backtrace()
            onerror(rootnode, val, node, CapturedException(err, bt))
        end
    finally
        timestep[] = ts
    end
end

# Default error handler function
function print_error(node, val, error_node, ex)
    lock(io_lock)
    io = STDERR
    println(io, "Failed to push!")
    print(io, "    ")
    show(io, val)
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
