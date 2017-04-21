import Base: push!, eltype, close
export Signal, push!, value, preserve, unpreserve, close, rename!

using DataStructures

##### Signal #####

const debug_memory = false # Set this to true to debug gc of nodes

const nodeset = WeakKeyDict()
const io_lock = ReentrantLock()

if !debug_memory
    type Signal{T}
        id::Int # also its index into `nodes`, and `edges`
        value::T
        parents::Tuple
        active::Bool
        actions::Vector
        preservers::Dict
        name::String
        function (::Type{Signal{T}}){T}(v, parents, pres, name)
            id = length(nodes) + 1
            n=new{T}(id, v, parents, false, Action[], pres, name)
            push!(nodes, WeakRef(n))
            push!(edges, Int[])
            foreach(p->push!(edges[p.id], id), parents)
            finalizer(n, remove_actions!)
            n
        end
    end
else
    type Signal{T}
        id::Int
        value::T
        parents::Tuple
        active::Bool
        actions::Vector
        preservers::Dict
        name::String
        bt
        function (::Type{Signal{T}}){T}(v, parents, actions, pres, name)
            id = length(nodes) + 1
            n=new{T}(id, v, parents, false, Action[], pres, name, backtrace())
            push!(nodes, WeakRef(n))
            push!(edges, Int[])
            foreach(p->push!(edges[p.id], id), parents)
            finalizer(n, remove_actions!)
            nodeset[n] = nothing
            finalizer(n, log_gc)
            n
        end
    end
end

Signal{T}(x::T, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, Dict{Signal, Int}(), name)
Signal{T}(::Type{T}, x, parents=(); name::String=auto_name!("input")) =
    Signal{T}(x, parents, Dict{Signal, Int}(), name)
# A signal of types
Signal(t::Type; name::String = auto_name!("input")) = Signal(Type, t, name)

log_gc(n) =
    @async begin
        lock(io_lock)
        print(STDERR, "Signal got gc'd. Creation backtrace:")
        Base.show_backtrace(STDERR, n.bt)
        println(STDOUT)
        unlock(io_lock)
    end

# TODO remove this, don't need recipient anymore so can just change all to Functions
immutable Action
    recipient::WeakRef
    f::Function
end

const action_queue = Action[] # stores the list of actions to perform, in order
const nodes = WeakRef[] #stores the nodes in order of creation (which is a topological order for execution of the nodes' actions)
const edges = Vector{Int}[] #parents to children, useful for plotting graphs
const first_action = WeakKeyDict{WeakRef, Int}()

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
    end
    node.active && return true #needed for fps node timers, and bind!
    return false
end

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
    write(io, "$(n.name): Signal{$(eltype(n))}($(n.value))")

value(n::Signal) = n.value
value(::Void) = false
eltype{T}(::Signal{T}) = T
eltype{T}(::Type{Signal{T}}) = T

##### Connections #####

# When an action is added to a node, we need to recreate the ordered list of actions
function refresh_action_queue()
    empty!(action_queue)
    for node in nodes
        first_action[node] = length(action_queue) + 1
        node.value != nothing && append!(action_queue, node.value.actions)
    end
    nothing
end

function add_action!(f, node)
    a = Action(WeakRef(node), f)
    push!(node.actions, a)
    refresh_action_queue()
    maybe_restart_queue()
    a
end

"""
Removes `action` from `node.actions` and action_queue
"""
function remove_action!(node, action)
    neq_action(queue_action) = queue_action != action
    filter!(neq_action, node.actions)
    filter!(neq_action, action_queue)
    nothing
end

"""
Remove all actions associated with the node from action_queue
"""
function remove_actions!(node)
    filter!(action_queue) do action
        action.recipient.value != node
    end
    nothing
end

function close(n::Signal, warn_nonleaf=true)
    remove_actions!(n)
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
        # @show pushnode val _active_binds _bindings
        # TODO test speed with and without first_action
        # @show "run_push" pushnode val action_queue
        # TODO check when/why first_action doesn't contain node...
        startfrom = haskey(first_action, node) ? first_action[node] : 1
        # @show startfrom
        for action in action_queue[startfrom:end]
            node = action.recipient.value
            if node != nothing && isrequired(node)
                # @show action
                node.active = true
                action.f(node) # TODO make all actions 0-arg anons - I don't think any of them need the node passed to them... they all have them in their closures
            end
        end
        # reset active status to false for all nodes downstream from pushnode
        for node in nodes[pushnode.id:end]
            # node.value != nothing && node.value.active && println("active: $node")
            node.value != nothing && (node.value.active = false)
        end
    catch err
        if isa(err, InterruptException)
            info("Reactive event loop was inturrupted.")
            rethrow()
        else
            bt = catch_backtrace()
            try
                onerror(pushnode, val, node, CapturedException(err, bt))
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

function print_error_and_rethrow(pushnode, val, error_node, ex)
    print_error(pushnode, val, error_node, ex)
    rethrow()
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
