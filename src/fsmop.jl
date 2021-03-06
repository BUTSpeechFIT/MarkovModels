# Implementation of common FSM operations.

#######################################################################
# FSM transpose

"""
    transpose(fsm)

Transpose the fsm, i.e. reverse all it's arcs. The final state becomes
the initial state.
"""
function Base.transpose(fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()
    smap = Dict(initstateid => finalstate(nfsm), finalstateid => initstate(nfsm))
    for s in states(fsm)
        (isinit(s) || isfinal(s)) && continue
        smap[s.id] = addstate!(nfsm, id = s.id, pdfindex = s.pdfindex, label = s.label)
    end

    for l in links(fsm)
        link!(smap[l.dest.id], smap[l.src.id], l.weight)
    end
    nfsm
end

#######################################################################
# Union of FSMs

"""
    union(fsm1, fsm2, ...)
    ∪(fsm1, fsm2, ...)

Merge several FSMs into a single one.
"""
function Base.union(fsm1::AbstractFSM{T}, fsm2::AbstractFSM{T}) where T
    fsm = FSM{T}()

    smap = Dict{State, State}(initstate(fsm1) => initstate(fsm),
                              finalstate(fsm1) => finalstate(fsm))
    for s in states(fsm1)
        if s.id == finalstateid || s.id == initstateid continue end
        smap[s] = addstate!(fsm, pdfindex = s.pdfindex, label = s.label)
    end
    for l in links(fsm1) link!(smap[l.src], smap[l.dest], l.weight) end

    smap = Dict{State, State}(initstate(fsm2) => initstate(fsm),
                              finalstate(fsm2) => finalstate(fsm))
    for s in states(fsm2)
        if s.id == finalstateid || s.id == initstateid continue end
        smap[s] = addstate!(fsm, pdfindex = s.pdfindex, label = s.label)
    end
    for l in links(fsm2) link!(smap[l.src], smap[l.dest], l.weight) end

    fsm
end
Base.union(fsm::AbstractFSM, rest::AbstractFSM...) = foldl(union, rest, init=fsm)

#######################################################################
# Concatenation

"""
    concat(fsm1, fsm2, ...)

Concatenate several FSMs into single FSM.
"""
function concat(fsm1::AbstractFSM{T}, fsm2::AbstractFSM{T}) where T
    fsm = FSM{T}()

    cs = addstate!(fsm) # special non-emitting state for concatenaton
    smap = Dict(initstate(fsm1) => initstate(fsm), finalstate(fsm1) => cs)
    for s in states(fsm1)
        (isinit(s) || isfinal(s)) && continue
        smap[s] = addstate!(fsm, pdfindex = s.pdfindex, label = s.label)
    end
    for l in links(fsm1) link!(smap[l.src], smap[l.dest], l.weight) end

    smap = Dict(initstate(fsm2) => cs, finalstate(fsm2) => finalstate(fsm))
    for s in states(fsm2)
        (isinit(s) || isfinal(s)) && continue
        smap[s] = addstate!(fsm, pdfindex = s.pdfindex, label = s.label)
    end
    for l in links(fsm2) link!(smap[l.src], smap[l.dest], l.weight) end

    fsm
end
concat(fsm1::AbstractFSM, rest::AbstractFSM...) = foldl(concat, rest, init=fsm1)

#######################################################################
# Weight normalization

"""
    weightnormalize(fsm)

Change the weight of the links such that the sum of the exponentiated
weights of the outgoing links from one state will sum up to one.
"""
function weightnormalize(fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()
    smap = Dict(
        initstateid => initstate(nfsm),
        finalstateid => finalstate(nfsm)
    )
    for s in states(fsm)
        (isinit(s) || isfinal(s)) && continue
        smap[s.id] = addstate!(nfsm, pdfindex = s.pdfindex, label = s.label)
    end

    for s in states(fsm)
        total = -Inf
        for l in links(s) total = logaddexp(total, l.weight) end
        for l in links(s)
            link!(smap[l.src.id], smap[l.dest.id], l.weight - total)
        end
    end
    nfsm
end

#######################################################################
# FSM determinization

"""
    determinize(fsm)

Transform `fsm` such that each state has at most one link to any other
states.
"""
function determinize(fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()
    newstates = Dict(
        initstate(fsm) => initstate(nfsm),
        finalstate(fsm) => finalstate(nfsm)
    )
    for state in states(fsm)
        (isfinal(state) || isinit(state)) && continue
        newstates[state] = addstate!(nfsm, pdfindex = state.pdfindex, label = state.label)
    end

    newlinks = Dict()
    for link in links(fsm)
        key = (link.src, link.dest)
        w₀ = get(newlinks, key, -Inf)
        newlinks[key] = logaddexp(w₀, link.weight)
    end

    for key in keys(newlinks)
        src, dest = key
        weight = newlinks[key]
        link!(newstates[src], newstates[dest], weight)
    end

    nfsm
end

#######################################################################
# FSM minimization

# propagate the weight of each link through the graph
function _distribute(fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()

    newstates = Dict(initstate(fsm) => initstate(nfsm),
                     finalstate(fsm) => finalstate(nfsm))
    for state in states(fsm)
        (isinit(state) || isfinal(state)) && continue
        newstates[state] = addstate!(nfsm, pdfindex = state.pdfindex, label = state.label)
    end

    stack = [(initstate(fsm), 0.0)]
    while ! isempty(stack)
        state, weight = popfirst!(stack)

        for link in links(state)
            link!(newstates[state], newstates[link.dest], weight + link.weight)
            push!(stack, (link.dest, weight + link.weight))
        end
    end

    nfsm
end

function _leftminimize(fsm::AbstractFSM{T}) where T
    # 1. Build the tree of string generated by the FSM
    tree = Dict()
    stack = [(initstate(fsm), tree)]
    while ! isempty(stack)
        state, node = popfirst!(stack)
        statepool = Dict()
        for link in links(state)
            key = (link.dest.pdfindex, link.dest.label)
            pstate = get(statepool, key, link.dest)
            statepool[key] = pstate
            s = (link.dest.pdfindex, link.dest.label)
            weight, nextlvl = get(node, s, (-Inf, Dict()))
            node[s] = (logaddexp(link.weight, weight), nextlvl, pstate)
            push!(stack, (link.dest, node[s][2]))
        end
    end

    # 2. Build the new fsm from the tree
    nfsm = FSM{T}()
    stack = [(initstate(nfsm), tree)]
    newstates = Dict()
    newlinks = Set()
    while ! isempty(stack)
        src, node = popfirst!(stack)

        for key in keys(node)
            (pdfindex, label) = key
            weight, nextlvl, state = node[key]

            if state ∉ keys(newstates)
                if isfinal(state)
                    newstates[state] = finalstate(nfsm)
                else
                    newstates[state] = addstate!(nfsm, pdfindex = pdfindex, label = label)
                end
            end

            dest = newstates[state]
            if (src, dest) ∉ newlinks
                link!(src, dest, weight)
                push!(newlinks, (src, dest))
            end

            if ! isfinal(state)
                push!(stack, (dest, nextlvl))
            end
        end
    end

    nfsm
end

"""
    minimize(fsm)

Merge equivalent states to reduce the size of the FSM. Only
the states that have the same `pdfindex` and the same `label` can be
potentially merged.

!!! warning
    The input FSM should not contain cycles otherwise the algorithm
    will never end.
"""
minimize(fsm::AbstractFSM) = (weightnormalize ∘ transpose ∘ _leftminimize ∘ transpose ∘ _leftminimize ∘ _distribute)(fsm)

#######################################################################
# NIL state removal

"""
    removenilstates(fsm)

Remove all states that are non-emitting and have no labels (except the
the initial and final states)
"""
function removenilstates(fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()

    newstates = Dict(initstate(fsm) => initstate(nfsm),
                     finalstate(fsm) => finalstate(nfsm))
    for state in states(fsm)
        (! islabeled(state) && ! isemitting(state)) && continue
        newstates[state] = addstate!(nfsm, pdfindex = state.pdfindex,
                                     label = state.label)
    end

    newlinks = Dict()
    stack = [(initstate(fsm), initstate(fsm), 0.0)]
    visited = Set([initstate(fsm)])
    while ! isempty(stack)
        src, state, weight = popfirst!(stack)
        for link in links(state)
            if link.dest ∈ keys(newstates)
                link!(newstates[src], newstates[link.dest], weight + link.weight)
                if link.dest ∉ visited
                    push!(visited, link.dest)
                    push!(stack, (link.dest, link.dest, 0.0))
                end
            else
                push!(stack, (src, link.dest, weight + link.weight))
            end
        end
    end

    nfsm
end

#######################################################################
# Composition

"""
    compose(subfsms::Dict, fsm)
    Base.:∘(subfsms::Dict, fsm)

Replace each state `s` in `fsm` by a "subfsms" from `subfsms` with
associated label `s.label`. `subfsms` should be a Dict{<:Label, FSM}`.
"""
function compose(subfsms::Dict, fsm::AbstractFSM{T}) where T
    nfsm = FSM{T}()

    newsrcs = Dict(initstate(fsm) => initstate(nfsm),
                   finalstate(fsm) => finalstate(nfsm))
    newdests = Dict(initstate(fsm) => initstate(nfsm),
                    finalstate(fsm) => finalstate(nfsm))

    for state in states(fsm)
        (isinit(state) || isfinal(state)) && continue
        if state.label ∈ keys(subfsms)
            s_fsm = subfsms[state.label]

            newstates = Dict(initstate(s_fsm) => addstate!(nfsm),
                             finalstate(s_fsm) => addstate!(nfsm, label = state.label))
            for state2 in states(s_fsm)
                (isinit(state2) || isfinal(state2)) && continue
                newstates[state2] = addstate!(nfsm, pdfindex = state2.pdfindex,
                                              label = state2.label)
            end

            for link in links(s_fsm)
                link!(newstates[link.src], newstates[link.dest], link.weight)
            end

            newdests[state] = newstates[initstate(s_fsm)]
            newsrcs[state] = newstates[finalstate(s_fsm)]
        else
            nstate = addstate!(nfsm, pdfindex = state.pdfindex,
                               label = state.label)
            newsrcs[state] = nstate
            newdests[state] = nstate
        end
    end

    for link in links(fsm)
        link!(newsrcs[link.src], newdests[link.dest], link.weight)
    end

    nfsm
end

Base.:∘(subfsms::Dict, fsm::AbstractFSM) = compose(subfsms, fsm)

