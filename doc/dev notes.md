## Developer Notes

### GC and Preserve

##### Docstring

`preserve(signal::Signal)`

prevents `signal` from being garbage collected (GC'd) as long as any of its `parents` are around. Useful for when you want to do some side effects in a signal.

e.g. `preserve(map(println, x))` - this will continue to print updates to x, until x goes out of scope. `foreach` is a shorthand for `map` with `preserve`.

##### Implementation

1. `preserve(x)` iterates through the parents of `x` and increases the count of `p.preservers[x]` by 1, and calls `preserve(p)` for each parent `p` of `x`.
1. Each signal has a field `preservers`, which is a `Dict{Signal, Int}`, which basically stores the number of times `preserve(x)` has been called on each of its child nodes `x`
1. Crucially, this Dict holds an active reference to `x` which stops it from getting GC'd
1. `unpreserve(x)` reduces the count of `preservers[x]` in all of x's parents, and if the count goes to 0, deletes the entry for (reference to) `x` in the `preservers` Dict thus freeing x for garbage collection.
1. Both `preserve` and `unpreserve` are also called recursively on all parents/ancestors of `x`, this means that all ancestors of x in the signal graph will be preserved, until their parents are GC'd or `unpreserve` is called the same number of times as `preserve` was called on them, or any of their descendants.
