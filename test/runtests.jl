using Reactive

# Stop the runner task

try
    Reactive.stop()
catch
end

include("basics.jl")
#include("gc.jl")
# include("node_order.jl")
# include("call_count.jl")
# include("flatten.jl")
# include("time.jl")
# include("async.jl")
FactCheck.exitstatus()
