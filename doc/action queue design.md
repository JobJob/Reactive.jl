###Action Queue Design

Every time a node is pushed to a sequence of actions takes place. This action sequence can, to a large extent, be determined as the signal graph is being created. So for each (root) node that can be `push!`ed to, a vector of actions - an `action_queue` - is set up and stored in `action_queues[node]`. When `node`s are created that depend on other nodes, they are added to all the appropriate action queues, i.e. the `Set` of action queues that the parent nodes are in.

Each node uses the field `roots` to store the keys of the action_queues they are in.

#### Filter

Filter works by setting the (node associated with the*) action to inactive. If all of a node's parents that have been processed so far in the current action queue are inactive then the node will not run it's action.

\* See To do 1. below

#### Flatten

Implementation is a bit tricky. See comments in code for how graph is rewired.

####To do
 1. Add an `active` field to `Action`s. Change the use of node.alive, in filter to just use action.alive, to avoid conflating the two meanings.
 1. Test performance vs orig design
 1. Sort out GC by using more WeakRefs and implementing close properly
 1. remove timestep
