using FactCheck
using Reactive

step() = Reactive.run(1)

facts("Async") do

    context("async_map") do
        x = Signal(1)
        t, y = async_map(-, 0, x)
        z = map(yv->2yv, y)

        @fact value(t) --> nothing
        @fact value(y) --> 0
        @fact value(z) --> 0

        push!(x, 2)
        step()
        step()

        @fact value(y) --> -2
        @fact value(z) --> -4
    end
end
