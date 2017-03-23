using Base.Test
using Reactive

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
        e = map(*, a, d) #e is dependent on a directly and through d
        @fact value(e) --> 1
        push!(a, 3)
        step()
        @fact value(e) --> 9
        push!(c, b)
        @fact value(e) --> 9
        step()
        @fact value(e) --> 6
        push!(a,4)
        @fact value(e) --> 6
        step()
        @fact value(e) --> 8 #e should still update on pushes to a
    end

end
