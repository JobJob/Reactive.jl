import Base: push!, eltype, close
export Signal, push!, value, preserve, unpreserve, close, rename!

using DataStructures

##### Signal #####

const debug_memory = false # Set this to true to debug gc of nodes

const nodes = WeakKeyDict()
const root_nodes = WeakKeyDict()
const io_lock = ReentrantLock()

if !debug_memory
    type Signal{T}
        value::T
        parents::Tuple
        roots::Tuple
        active::Bool
        alive::Bool
        preservers::Dict
        name::String
        function (::Type{Signal{T}}){T}(v, parents, alive, pres, name)
            roots = getroots(parents)
            n=new{T}(v, parents, roots, false, alive, pres, name)
            if isempty(roots)
                #root node, init action queue
                action_queues[n] = []
                root_nodes[n] = nothing
            end
            finalizer(n, remove_actions!)
            n
        end
    end
else
    type Signal{T}
        value::T
        parents::Tuple
        roots::Tuple
        active::Bool
        alive::Bool
        preservers::Dict
        name::String
        bt
        function (::Type{Signal{T}}){T}(v, parents, actions, alive, pres, name)
            roots = getroots(parents)
            n=new{T}(v,parents,roots,false,alive,pres,name,backtrace())
            isroot(n) && (action_queues[n] = []) #root node
            nodes[n] = nothing
            finalizer(n, log_gc)
            n
        end
    end
end

Signal{T}(x::T, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, true, Dict{Signal, Int}(), name)
Signal{T}(::Type{T}, x, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, true, Dict{Signal, Int}(), name)
# A signal of types
Signal(t::Type; name::String = auto_name!("input")) = Signal(Type, t, name)

"""
Nodes are roots if they have an empty `node.roots`. We choose to set it as
empty, rather than having `node.roots == (node,)` to avoid an unecessary
self-reference - which would require working around problems with printing,
saving to disk etc. Instead, wherever we need the roots of a `node` to include
the root node itself we call `allroots(node)`.
"""
isroot(node) = haskey(root_nodes, node)

"""
`allroots(node)::Tuple{Vararg{Signal}}`
Returns the list of roots that are keys into `action_queues` that this node's
descendents are in. So if `node` is a root node, includes itself as the first
root in the returned list of roots, otherwise just returns node.roots
"""
allroots(maybe_root_node) = isroot(maybe_root_node) ?
    (maybe_root_node, maybe_root_node.roots...) : # maybe_root_node must be first, relied on in queue_subtree_actions
    maybe_root_node.roots

"""
`allroots()` returns all root nodes currently alive
"""
allroots() = collect(keys(root_nodes))

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

function isrequired(node::Signal)
    for p in node.parents
        #any active parent and we are go
        p.active && return true
        # for flatten nodes, their parent is a Signal{Signal}
        # their action isrequired if the parent is active (like other sigs: handled above)
        # or if the current Signal of the parent (value(p)) is active:
        (eltype(p) <: Signal) && value(p).active && return true
    end
    node.active && return true #needed for fps node timers
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
    write(io, "$(n.name): Signal{$(eltype(n))}($(n.value)$(n.alive ? "" : ", closed"))")

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
    end
    maybe_restart_queue()
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

"""
remove the action associated with the node from all of its roots' action_queues
"""
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
    remove_actions!(n)
    n.alive = false #TODO remove, not used anymore
    for p in n.parents
        delete!(p.preservers, n)
    end
    finalize(n) # stop timer etc.
end

send_value!(node::Signal, x) = (node.value = x)

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

The third (optional) argument, `onerror`, is a callback triggered when
the update ends in an error. The callback receives 4 arguments,
`onerror(sig, val, node, capex)`, where `sig` and `val` are the Signal
and value that `push!` was called with, respectively, `node` is the
Signal whose action triggered the error, and `capex` is a
`CapturedException` with the fields `ex` which is the original
exception object, and `processed_bt` which is the backtrace of the
exception.

The default error callback will print the error and backtrace to STDERR.
"""
function Base.push!(n::Signal, x, onerror=print_error)
    if async_mode[]
        async_push!(n, x, onerror)
    else
        run_push(n, x, onerror)
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
    for i=1:n
        message = take!(_messages)
        isnull(message) && break # break on null messages

        msgval = get(message)
        run_push(msgval.node, msgval.value, msgval.onerror)
    end
end

function run_push(pushnode, val, onerror)
    node = pushnode # ensure node is set for error reporting - see onerror below
    try
        send_value!(pushnode, val)
        pushnode.active = true

        action_queue =
            if haskey(action_queues, pushnode)
                # pushnode is a root/input node
                action_queues[pushnode]
            else
                # pushnode is a non-root/input node, so we use any old
                # action_queue that pushnode is in. Why? Because it'll have
                # all actions downstream of pushnode, which we want to run,
                # and even though it'll also have actions for ancestors of
                # pushnode, which we don't want to run, they won't be run since
                # none of their parents will be active so isrequired will return
                # false for all of them.
                action_queues[first(allroots(pushnode))]
            end
        # @show "run_push" pushnode val action_queue
        for action in action_queue
            node = action.recipient.value
            if isrequired(node)
                node.active = true
                action.f(node)
            end
        end
        #reset active status to false for all nodes
        for action in action_queue
            action.recipient.value.active = false
        end
    catch err
        if isa(err, InterruptException)
            info("Reactive event loop was inturrupted.")
            rethrow()
        else
            bt = catch_backtrace()
            try
                msgval.onerror(msgval.node, msgval.value, node, CapturedException(err, bt))
            catch err_onerror
                if isa(err_onerror, MethodError)
                    println(STDERR, "The syntax for `onerror` has changed, see ?push!")
                end
                rethrow()
            end
        end
    end
end

# Default error handler function
function print_error(pushnode, val, error_node, ex)
    lock(io_lock)
    io = STDERR
    println(io, "Failed to push!")
    print(io, "    ")
    show(io, val)
    println(io)
    println(io, "to node")
    print(io, "    ")
    show(io, pushnode)
    println(io)
    println(io)
    println(io, "error at node: $error_node")
    showerror(io, ex)
    println(io)
    unlock(io_lock)
end

# Run everything queued up till the instant of calling this function
run_till_now() = run(Base.n_avail(_messages))

# Works around world age problems (see issue #131)
function maybe_restart_queue()
    global runner_task
    if !istaskdone(runner_task)
        stop()
        wait(runner_task)
        runner_task = @async run()
    end
end

function __init__()
    global runner_task = @async run()
end
