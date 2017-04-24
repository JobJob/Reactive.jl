### Node Creation Order Design

When a node is `push!`ed to in user code, this library must process it and ensure signal values stay consistent with the operations users used to define the chain of signals (e.g. map, foldp, etc.).

(N.b. "node" and "Signal" are used interchangeably in this doc and the code)

The design assumes:

1. The order which nodes are created is a correct [topological ordering](https://en.wikipedia.org/wiki/Topological_ordering) (with the edges of the signal graph  regarded as directed from parents to children)
2. Signals will end up in a correct state if the order in which each node is processed and their update actions (e.g. the mapped function in the case of a map) run, is the same as the order in which nodes were created.
3. Signal actions should be run for a given `push!` only if the node itself was pushed to or if one of their parents had their actions run.

This should ensure that parents of nodes update before their children, and signal values will be in a correct state after each `push!` has been processed.

#### Basics

Each node (`Signal`) is added to the end of a Vector called `nodes` on creation, so that `nodes` holds Signals in the order they were created.

Each Signal holds a field `actions` which are basically just 0-argument functions that update the value of the node or perform some helper function to that end.

Each Signal also has a field `active` which stores whether or not the node was active (had its actions run) in the current push. A Signal will be set to active if it is `push!`ed to, or if any of its parent `Signal`s were active.

On processing each `push!`, we run through `nodes` and execute the actions of each node if any of its parents were active.

#### Filter

Filter works by setting the filter node's active field to false when the filter condition is false. Downstream/descendent nodes check if at least one of their parents has been active, if none of them have been active then the node will not run its action, thus propagating the filter correctly.

#### More info

Please feel free to open issues if things are not clear.
