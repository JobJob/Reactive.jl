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
1. fps, fpswhen (the action sets up a timer to push to the output node, and is added as a foreach on the input node, and an action on the output node. The foreach runs when the switch updates, the action on the output node runs when the timer pushes to it. The latter is the usual way the next tick/push is set up, it relies on the `node == pushnode && length(node.parents) == 0` test in actions_required. As such, fpswhen can't have the switch node as a parent - it can't have any parents. See Operator Rules below for more details.
1. every (doesn't actually have an action, just creates a timer to push to itself repeatedly)

Action pushes to another node
1. throttle (the action is on a foreach on the input node, which sets up a timer to push to the throttle node)
1. delay (the action is on a foreach on the input node, which just pushes to the delay node)

Action sets the value of another node
1. bind! (action is a `map` on the src node, which calls set_value! on the dest node, and returns nothing). This allows the action to run, even if the node is a non-input, but gets pushed to, e.g. from test/basics.jl "non-input bind":
```
s = Signal(1; name="sig 1")
m = map(x->2x, s; name="m")
s2 = Signal(3; name="sig 2")
push!(m, 10) # s,m,s2 should be 1, 10, 3

bind!(m, s2) # s,m,s2 should be 1, 3, 3

push!(m, 6) # s,m,s2 should be 1, 6, 6

push!(s2, 10) # s,m,s2 should be 1, 10, 10
```

### Operator rules

Because of the way `action_required` works, the following rules should be followed when making/modifying operators:

1. Don't attach actions to parent/input nodes, instead use `foreach(action_fn, parent)`, this is used by:
    1. delay - added to the input node
    1. throttle - added to the input node
    1. fpswhen - added to the switch to set up the first tick/or stop the timer.
    1. bind - added to the src
1. If the node getting pushed to has actions that need to run on every push (e.g. fpswhen), it can't have any parents, since it needs this test to be true: `node == pushnode && length(node.parents) == 0`

The test for `length(node.parents) == 0` is there to allow pushes to non-input nodes to update the node's value, without running the node's actions (which would often incorrectly overwrite the node's value). e.g.

```
s = Signal(1)
doubler(x) = 2x
m = map(doubler, s) # m is now 2
push!(m, 10)
```
if the map's action (doubler) ran, it would set `m` back to 2, since `s` is still 1, but because map has `s` as a parent, `length(node.parents) == 1` (!= 0) so the map's action (doubler) doesn't run, and m's value becomes 10, as desired.

Note that this change to 10 will propagate to m's descendents, since the pushed to node (m in this case) is always active, even if its action(s) don't run.

The non-running of actions for node's pushed to that have non-empty parents, is why it's not recommended to add actions on parent nodes, since they won't run in those cases. `foreach`es on those nodes will run, hence rule 1 above.

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
