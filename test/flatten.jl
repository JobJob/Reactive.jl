using Base.Test
using Reactive
# import Reactive: action_queue

facts("Flatten") do

    a = Signal(0)
    b = Signal(1)

    c = Signal(a)

    d = flatten(c)
    cnt = foldp((x, y) -> x+1, 0, d)

    context("Signal{Signal} -> flat Signal") do
        # Flatten implies:
        @fact value(c) --> a
        @fact value(d) --> value(a)
    end

    context("Initial update count") do
        @fact value(cnt) --> 0
    end

    context("Current signal updates") do
        push!(a, 2)
        step()

        @fact value(cnt) --> 1
        @fact value(d) --> value(a)
    end

    context("Signal swap") do
        push!(c, b)
        step()
        @fact value(cnt) --> 2
        @fact value(d) --> value(b)

        push!(a, 3)
        step()
        @fact value(cnt) --> 2
        @fact value(d) --> value(b)

        push!(b, 3)
        step()

        @fact value(cnt) --> 3
        @fact value(d) --> value(b)
    end

    context("Subtle sig swap issue") do
        a = Signal(1)
        b = Signal(2)
        c = Signal(a)
        d = flatten(c)
        e = map(*, a, d) #e is dependent on "a" directly and through d

        # @fact length(action_queues[a]) --> 2 # d & e should update when "a" updates
        # @fact length(action_queues[b]) --> 0 # nothing depends on b atm
        # @fact length(action_queues[c]) --> 2 # d & thus e should update when c updates

        @fact value(e) --> 1
        push!(a, 3)
        step()
        @fact value(a) --> 3
        @fact value(d) --> 3
        @fact value(e) --> 9

        push!(c, b)
        @fact value(e) --> 9 # no change until step
        step()
        @fact value(d) --> 2 # d now takes b's value
        @fact value(e) --> 6 # e == d * a == 2 * 3 == 6

        # the push!(c, b) should have triggered a "rewiring" of the graph
        # @fact length(action_queues[a]) --> 1 # only e should update when "a" updates
        # @fact length(action_queues[b]) --> 2 # d & thus e should update when b updates
        # @fact length(action_queues[c]) --> 2 # d & thus e should still update when c updates

        push!(a, 4)
        @fact value(e) --> 6 # no change until step
        step()
        @fact value(a) --> 4
        @fact value(d) --> 2
        @fact value(e) --> 8 #e should still update on pushes to a

        @fact queue_size() --> 0
    end

end
