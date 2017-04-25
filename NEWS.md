v0.4.1
------
* Performance improvements
* Fix bugs in signal update ordering - see test/node_order.jl ("dfs bad", and "bfs bad, dfs bad") for examples fixed
* Fix for #123 changes the behaviour of `throttle`, for the old behaviour, use `debounce`

v0.4.0
------
* API for `onerror` changed, see `?push!` for details`

v0.1.8
------
* Mix in Timing module into Reactive and remove it
