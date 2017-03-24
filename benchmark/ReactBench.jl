using Reactive, GLAbstraction, GeometryTypes

N = 10^6
function test1(; use_async = true)
    # Reactive.run_async(use_async)
    a = Signal(0.0)

    b = map(/, a, Signal(23.0))
    c = map(/, a, Signal(8.0))
    f = foldp(+, 0.0, b)

    d = map(Vec3f0, b)
    e = map(Vec3f0, c)
    g = map(Vec3f0, f)

    m = map(translationmatrix, d)
    m2 = map(translationmatrix, e)

    m3 = map(*, m, m2)
    # I don't know why, but Mat*Vec is broken right now
    result = map(m3, g) do a, b
         r = a * Vec4f0(b, 1)
         Vec3f0(r[1], r[2], r[3])
    end

    total_time = 0.0

    for i=1:N
        tic()
#         @async push!(a, i)
        push!(a, i)
        use_async && Reactive.run_till_now()
        total_time += toq()
    end
    @show(total_time)
    @show(total_time/N)
    total_time
end

function bf(a,c)
    a/c
end
begin
    local accum = 0.0
    function ff(a)
        accum += a
    end
end
function test2()
    total_time = 0.0
    a = 0.0
    for i=1:N
        tic()

        a = i
        b = bf(a, 23.0)
        c = bf(a, 8.0)
        f = ff(a)
        d = Vec3f0(b)
        e = Vec3f0(c)
        g = Vec3f0(f)

        m = translationmatrix(d)
        m2 = translationmatrix(e)

        m3 = m*m2
        r = m3 * Vec4f0(g, 1)
        result = Vec3f0(r[1], r[2], r[3])
        total_time += toq()
    end
    @show(total_time)
    @show(total_time/N)
    total_time
end
react_time = test1()
regular_time = test2()
react_time/regular_time
