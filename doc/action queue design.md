### Action Queue Design

Every time a node is pushed to a sequence of actions takes place. This action sequence can, for the most part, be determined as the signal graph is being created. So for each (root/input) node, a vector of actions - an `action_queue` - is set up and stored in `action_queues[node]`. When `node`s are created that depend on other nodes, they are added to all the appropriate action queues, i.e. all the action_queues that the parent nodes are in.

Each node uses the field `roots` to store the keys (nodes) of the action_queues they are in.

#### Filter

Filter works by setting the filter node's active field to false when the filter condition is false. Downstream nodes (nodes later in the current `action_queue`) check if at least one of their parents has been active, if none of them have been active then the node will not run it's action, thus propagating the filter correctly.

#### Flatten

Implementation is a bit fiddly. See comments in the code for how the graph is rewired.

#### More info

Please feel free to open issues if things are not clear.
