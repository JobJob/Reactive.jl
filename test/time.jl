import Reactive: set_test_debug

facts("Timing functions") do

    context("fpswhen") do
        b = Signal(false)
        t = fpswhen(b, 2)
        acc = foldp((x, y) -> x+1, 0, t)
        sleep(0.75)

        @fact queue_size() --> 0
        push!(b, true)

        dt = @elapsed Reactive.run(3) # the first one starts the timer
        push!(b, false)
        Reactive.run(1)

        sleep(0.11) # no more updates
        @fact queue_size() --> 0

        @fact dt --> roughly(1, atol=0.25) # mac OSX needs a lot of tolerence here
        @fact value(acc) --> 2

    end

    context("every") do
        t = every(0.5)
        acc = foldp(push!, Float64[], t)
        Reactive.run(4)
        end_t = time()
        log = copy(value(acc))

        @fact log[end-1] --> roughly(end_t, atol=0.01)

        close(acc)
        close(t)
        Reactive.run_till_now()

        @fact [0.5, 0.5, 0.5] --> roughly(diff(log), atol=0.1)

        sleep(0.75)
        # make sure close actually also closed the timer
        @fact queue_size() --> 0
    end

    context("throttle") do
        set_test_debug()
        # get compilation time out of the way
        # _x = Signal(0)
        # _y = throttle(0.5, _x)
        # _y′ = throttle(1, _x, push!, Int[], v->Int[]) # collect intermediate updates
        # _z = foldp((acc, _x) -> acc+1, 0, _y)

        # start here
        x = Signal(0; name="x")
        push!(x, 1)
        push!(x, 2)
        push!(x, 3)
        y = throttle(0.8, x; name="y")
        t0 = time()
        y′ = throttle(1.6, x, push!, Int[], x->Int[]; name="y′") # collect intermediate updates
        z = foldp((acc, x) -> begin
            println(msnow(), "z returning $(acc+1)")
            acc+1
        end, 0, y)
        z′ = foldp((acc, x) -> begin
            println(msnow(), "z′ returning $(acc+1)")
            acc+1
        end, 0, y′)

        println("pre step 1")
        step()
        println("post step 1")

        println("pre step 2")
        step()
        println("post step 2")

        println("pre step 3")
        step()
        println("post step 3")

        @fact value(y) --> 0
        @fact value(z) --> 0
        @fact queue_size() --> 0

        time_since_ytimer_started = time() - t0
        sleep(0.9 - time_since_ytimer_started)

        # @fact queue_size() --> 1
        # step()
        Reactive.run_till_now()
        @fact value(y) --> 3
        @fact value(z) --> 1
        @fact value(z′) --> 0
        sleep(0.8 - time_since_ytimer_started)

        @fact queue_size() --> 1
        step()
        @fact value(z′) --> 1
        @fact value(y′) --> Int[1,2,3]

        push!(x, 3)
        step()

        push!(x, 2)
        step()

        push!(x, 1)
        step()
        sleep(1)

        @fact queue_size() --> 2
        step()
        step()
        @fact value(y) --> 1
        @fact value(z′) --> 2
        @fact value(y′) --> Int[3,2,1]

        # type safety
        s1 = Signal(3)
        s2 = Signal(rand(2,2))
        m = merge(s1, s2)
        t = throttle(1/5, m; typ=Any)
        r = rand(3,3)
        push!(s2, r)
        Reactive.run(1)
        sleep(0.5)
        Reactive.run(1)
        @fact value(t) --> r
    end
end
