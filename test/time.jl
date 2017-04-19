using Base.Test
using Reactive

# Reactive.stop()
#
# step() = Reactive.run(1)
# queue_size() = Base.n_avail(Reactive._messages)
# number() = round(Int, rand()*1000)

macro factwarm(testexpr)
    :(warmed_up && @fact $testexpr) |> esc
end

function bleed_out_queue()
    while queue_size() > 0
        Reactive.run_till_now()
    end
end

facts("Timing functions") so

    context(fpswhen) do
        function fpswhen_test(; warmed_up=false)
            b = Signal(false)
            t = fpswhen(b, 2)
            acc = foldp((x, y) -> x+1, 0, t)
            sleep(0.75)

            @factwarm queue_size() == 0
            push!(b, true)

            dt = @elapsed Reactive.run(3) # the first one starts the timer
            push!(b, false)
            Reactive.run(1)

            sleep(0.11) # no more updates
            @factwarm queue_size() == 0

            @factwarm isapprox(dt, 1, atol=0.25) # mac OSX needs a lot of tolerence here
            @factwarm value(acc) == 2
        end
        fpswhen_test(warmed_up=false)
        bleed_out_queue()
        fpswhen_test(warmed_up=true)
    end

    context(every) do
        function test_every(; warmed_up=false)
            t = every(0.5)
            acc = foldp(push!, Float64[], t)
            Reactive.run(4)
            end_t = time()
            log = copy(value(acc))

            @factwarm isapprox(log[end-1], end_t, atol=0.01)

            close(acc)
            close(t)
            Reactive.run_till_now()

            @factwarm isapprox(diff(log), [0.5, 0.5, 0.5], atol=0.1)

            sleep(0.75)
            # make sure close actually also closed the timer
            @factwarm queue_size() == 0
        end
        test_every(warmed_up=false)
        bleed_out_queue()
        test_every(warmed_up=true)
    end

    context(throttle) do
        function throttle_test(; warmed_up=false)
            x = Signal(0)
            t0 = time()
            y = throttle(0.5, x)
            y′ = throttle(1, x, push!, Int[], x->Int[]) # collect intermediate updates
            z = foldp((acc, x) -> acc+1, 0, y)
            z′ = foldp((acc, x) -> acc+1, 0, y′)

            push!(x, 1)
            step()

            push!(x, 2)
            step()

            push!(x, 3)
            step()

            @factwarm value(y) == 0
            @factwarm value(z) == 0
            dt = (time() - t0)
            @show dt
            @factwarm dt < 0.5
            @factwarm queue_size() == 0 #the throttle should have stopped any updates

            sleep(0.6)
            @factwarm queue_size() == 1
            step()
            @factwarm value(y) == 3
            @factwarm value(z) == 1
            @factwarm value(z′) == 0
            sleep(0.5)

            @factwarm queue_size() == 1
            step()
            @factwarm value(z′) == 1
            @factwarm value(y′) == Int[1,2,3]

            @factwarm queue_size() == 0
            push!(x, 4)
            step() #has been greater than 0.5 secs, will trigger push to y
            @factwarm value(y) == 3
            @factwarm value(z) == 1
            step()
            @factwarm value(y) == 4
            @factwarm value(z) == 2

            push!(x, 2)
            step()

            push!(x, 1)
            step()
            @factwarm value(y) == 4
            @factwarm value(z) == 2
            @factwarm queue_size() == 0
            sleep(1.1)

            @factwarm queue_size() == 2
            step()
            step()
            @factwarm value(y) == 1
            @factwarm value(z′) == 2
            @factwarm value(y′) == Int[4,2,1]

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
            @factwarm value(t) == r
        end
        throttle_test(warmed_up=false)
        bleed_out_queue()
        throttle_test(warmed_up=true)
    end
end
