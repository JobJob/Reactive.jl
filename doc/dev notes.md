## Developer Notes

### Operators

Action updates the node whose `actions` Vector it's in with `set_value!` (pre-updates, should not run when node is pushed to, i.e. no parents active):
1. map (multiple parents)
1. filter (calls deactivate! when f(value(input)) is false)
1. filterwhen (calls deactivate! when value(input) is false)
1. foldp
1. sampleon (sample trigger input is its only parent)
1. merge (multiple parents)
1. previous (caches the previous update)
1. droprepeats (calls deactivate! when value(input) == prev_value)
1. flatten (wire_flatten and set_flatten_val both get run whenever either the `current_node` or the `input` sigsig update. Would it be better to just add those actions to the input and current_node update respectively?)

Action pushes to itself
1. delay (the action checks for, and does not run when input not active, to avoid continually pushing to itself). Could probably just be added to `input` as a post-action.
1. fps, fpswhen (the action sets up a timer to push to the output node, and is added on the output node, so it runs when the switch updates (switch is the parent of output), or when the timer pushes to the node. The latter is the usual way the next tick/push is set up), it relies on running even if the parent is not active.
1. every (doesn't actually have an action, just creates a timer to push to itself repeatedly)

Action pushes to another node
1. throttle (the action is on the input node, which sets up a timer to push to the throttle node)

Action sets the value of another node
1. bind! (action is on the src node, and calls set_value! on the dest node)

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
