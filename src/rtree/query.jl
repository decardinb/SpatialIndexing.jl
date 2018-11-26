"""
Find `Leaf` in the `node` subtree by the `id` and `br` MBR of one of its `Elem`s.

Returns the tuple of `Leaf` and element position or `nothing`.
"""
function findleaf(node::Leaf{T,N}, reg::Region{T,N}, id::Any) where {T,N}
    for (i, el) in enumerate(children(node))
        if isequal_rtree(el, reg, id)
            return (node, i)
        end
    end
    return nothing
end

function findleaf(node::Branch{T,N,V}, reg::Region{T,N}, id::Any) where {T,N,V}
    for child in children(node)
        if contains(mbr(child), reg)
            res = findleaf(child, reg, id)
            if res !== nothing
                return res::Tuple{Leaf{T,N,V}, Int}
            end
        end
    end
    return nothing
end

findleaf(rtree::RTree{T,N}, reg::Region{T,N}, id::Any = nothing) where {T,N} =
    findleaf(rtree.root, reg, id)

# FIXME: currently isempty() doesn't allow specifying how
#        to treat overlapping elements (inside or not), currently treated as outside
"""
    isempty(tree::RTree, region::Region)

Check if there are `tree` elements inside `region`.
"""
Base.isempty(tree::RTree{T,N}, region::Region{T,N}) where {T,N} =
    _isempty(tree.root, region)

function _isempty(node::Node, region::Region{T,N}) where {T,N}
    isempty(node) && return true
    nodebr = mbr(node)
    if in(nodebr, region) # there are elements inside rect
        return false
    elseif intersects(nodebr, region) # there could be node elements inside region
        for child in children(node)
            if node isa Branch # should be optimized out at compile time
                _isempty(child, region) || return false
            elseif node isa Leaf
                in(mbr(child), region) && return false
            end
        end
    end
    return true
end

# the RTreeIterator/RTreeRegionQueryIterator state
# FIXME can mark whether the MBR of the node satisfies the query, so all
# its subnodes and data elements need not to be checked
struct RTreeIteratorState{T,N,V}
    leaf::Leaf{T,N,V}       # current leaf node
    indices::Vector{Int}    # indices of the nodes (in their parents) in the current subtree
end

# get the current data element pointed by `RTreeIteratorState`
Base.get(state::RTreeIteratorState) = @inbounds(state.leaf[state.indices[1]])

# iterate all R-tree data elements
function Base.iterate(tree::RTree)
    isempty(tree) && return nothing
    node = tree.root
    indices = fill(1, height(tree))
    # get the first leaf
    while level(node) > 0
        node = node[1]
    end
    state = RTreeIteratorState(node, indices)
    return get(state), state # first element of the first leaf
end

function Base.iterate(tree::RTree, state::RTreeIteratorState)
    @inbounds if state.indices[1] < length(state.leaf) # fast branch: next data element in the same leaf
        state.indices[1] += 1
        return get(state), state
    end
    # leaf iterations is done, go up until the first non-visited branch
    node = state.leaf
    while state.indices[level(node) + 1] >= length(node)
        hasparent(node) || return nothing # returned to root, iteration finished
        node = parent(node)
    end
    # go down into the first leaf of the new subtree
    ix = state.indices[level(node) + 1] += 1
    node = node[ix]
    @inbounds while true
        state.indices[level(node) + 1] = 1
        level(node) == 0 && break
        node = node[1]
    end
    new_state = RTreeIteratorState(node, state.indices)
    return get(new_state), new_state
end

# iterates R-tree data elements matching `Q` query w.r.t `region`
struct RTreeRegionQueryIterator{T,N,V,Q,TT,R} <: SpatialQueryIterator{T,N,V,Q}
    tree::TT
    region::R

    function RTreeRegionQueryIterator{T,N}(kind::QueryKind, tree::TT, region::R) where
            {T, N, V, TT <: RTree{T,N,V}, R <: Region{T,N}}
        new{T,N,V,kind,TT,R}(tree, region)
    end
end

function Base.iterate(iter::RTreeRegionQueryIterator)
    # no data or doesn't intersect at all
    if (isempty(iter.tree) || !should_visit(iter.tree.root, iter))
        #@debug "iterate(): empty iter=$iter root_visit=$(should_visit(iter.tree.root, iter))"
        return nothing
    end
    return _iterate(iter, iter.tree.root, fill(1, height(iter.tree)))
end

function Base.iterate(iter::RTreeRegionQueryIterator,
                      state::RTreeIteratorState)
    @inbounds ix = state.indices[1] = _nextchild(state.leaf, state.indices[1] + 1, iter)
    if ix <= length(state.leaf) # fast branch: next data element in the same leaf
        return get(state), state
    else
        return _iterate(iter, state.leaf, state.indices)
    end
end

"""
    contained_in(index::SpatialIndex, region::Region)

Get iterator for `index` elements contained in `region`.
"""
contained_in(tree::RTree{T,N}, region::Region{T,N}) where {T,N} =
    RTreeRegionQueryIterator{T,N}(QueryContainedIn, tree, region)

"""
    intersects_with(index::SpatialIndex, region::Region)

Get iterator for `index` elements intersecting with `region`.
"""
intersects_with(tree::RTree{T,N}, region::Region{T,N}) where {T,N} =
    RTreeRegionQueryIterator{T,N}(QueryIntersectsWith, tree, region)

# whether the R-tree node/data element should be visited (i.e. its children examined)
# by the region iterator
should_visit(node::Node, iter::RTreeRegionQueryIterator) =
    intersects(iter.region, mbr(node)) # FIXME update for NotContainedIn etc

should_visit(el::Any, iter::RTreeRegionQueryIterator) =
    ((querykind(iter) == QueryContainedIn) && contains(iter.region, mbr(el))) ||
    ((querykind(iter) == QueryIntersectsWith) && intersects(iter.region, mbr(el)))
    # FIXME update for NotContainedIn etc

# get the index of the first child of `node` starting from `pos` (including)
# that satifies `iter` query (or length(node) + 1 if not found)
@inline function _nextchild(node::Node, pos::Integer, iter::RTreeRegionQueryIterator)
    if level(node) == 0 && length(iter.tree) > 100 && pos <= length(node)
        #@debug "_nextchild(): lev=$(level(node)) len=$(length(node)) pos=$pos should_visit=$(should_visit(@inbounds(node[pos]), iter)) rect=$(mbr(node[pos]))"
    end
    while pos <= length(node) && !should_visit(@inbounds(node[pos]), iter)
        pos += 1
        if level(node) == 0 && length(iter.tree) > 100 && pos <= length(node)
            #@debug "_nextchild(): lev=$(level(node)) len=$(length(node)) pos=$pos should_visit=$(should_visit(@inbounds(node[pos]), iter)) rect=$(mbr(node[pos]))"
        end
    end
    return pos
end

# do depth-first search starting from the `node` subtree and return the
# `RTreeIteratorState` for the first leaf that satisfies `iter` query or
# `nothing` if no such leaf in the R-tree.
# The method modifies `indicies` array and uses it for the returned iteration state
function _iterate(iter::RTreeRegionQueryIterator, nod::Node, indices::AbstractVector{Int})
    node = nod
    #@debug"_iterate(): enter lev=$(level(node)) indices=$indices"
    @assert length(indices) == height(iter.tree)
    ix = @inbounds(indices[level(node) + 1])
    while true
        ix_new = _nextchild(node, ix, iter)
        #@debug "node=$(Int(Base.pointer_from_objref(node))) lev=$(level(node)) ix_new=$ix_new"
        if ix_new > length(node) # all node subtrees visited, go up one level
            while ix_new > length(node)
                if !hasparent(node)
                    #@debug "_iterate(): finished lev=$(level(node)) indices=$indices ix_new=$ix_new"
                    return nothing # returned to root, iteration finished
                end
                #@debug "_iterate(): up lev=$(level(node)) indices=$indices ix_new=$ix_new"
                node = parent(node)
                @inbounds ix_new = indices[level(node) + 1] += 1 # next subtree
            end
            ix = ix_new
            #@debug "_iterate(): next subtree lev=$(level(node)) indices=$indices ix_new=$ix_new"
        else # subtree found
            ix_new > ix && @inbounds(indices[level(node) + 1] = ix_new)
            if node isa Branch
                # go down into the first child
                indices[level(node)] = ix = 1
                node = node[ix_new]
                #@debug "_iterate(): down lev=$(level(node)) indices=$indices"
            else # Leaf
                #@debug "_iterate(): return lev=$(level(node)) indices=$indices"
                state = RTreeIteratorState(node, indices)
                return get(state), state
            end
        end
    end
end
