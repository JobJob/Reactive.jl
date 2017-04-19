### Action Queue Design

Every time a node is pushed to a sequence of actions takes place. This action sequence can, for the most part, be determined as the signal graph is being created. So for each (root/input) node, a vector of actions - an `action_queue` - is set up and stored in `action_queues[node]`. When `node`s are created that depend on other nodes, they are added to all the appropriate action queues, i.e. all the action_queues that the parent nodes are in.

Each node uses the field `roots` to store the keys (nodes) of the action_queues they are in.

Note that each action queues may have significant overlap with action queues for other roots. Specifically, if a node is in more than one action_queue (which would happen for any node which has more than one input/root node as an ancestor), all of its descendent/downstream nodes/actions will also be in all the action_queues it is in. This makes sense because no matter what root/input Signal that was `push!`ed to which caused the update to the node, all actions which depend on it should update too.

#### Filter

Filter works by setting the filter node's active field to false when the filter condition is false. Downstream nodes (nodes later in the current `action_queue`) check if at least one of their parents has been active, if none of them have been active then the node will not run its action, thus propagating the filter correctly.

#### Flatten and Bind

Implementations are a bit fiddly. See comments in the code for more details.

#### More info

Please feel free to open issues if things are not clear.
