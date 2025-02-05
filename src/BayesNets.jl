module BayesNets

export BayesNet, addEdge!, removeEdge!, addEdges!, removeEdges!, CPD, CPDs, prob, setCPD!, pdf, rand, randBernoulliDict, randDiscreteDict, table, domain, Assignment, *, sumout, normalize, select, randTable, NodeName, consistent, estimate, randTableWeighted, estimateConvergence, isValid, hasEdge
export Domain, BinaryDomain, DiscreteDomain, RealDomain, domain, cpd, parents, setDomain!, plot

import LightGraphs: DiGraph, Edge, rem_edge!, add_edge!, topological_sort_by_dfs, in_edges, src, dst, in_neighbors, is_cyclic
import TikzGraphs: plot
import Base: rand, select, *
import DataFrames: DataFrame, groupby, array, isna

typealias DAG DiGraph

typealias NodeName Symbol

typealias Assignment Dict

Base.zero(::Any) = ""

function consistent(a::Assignment, b::Assignment)
    commonKeys = intersect(keys(a), keys(b))
    reduce(&, [a[k] == b[k] for k in commonKeys])
end

include("cpds.jl")

typealias CPD CPDs.CPD

DAG(n) = DiGraph(n)

abstract Domain

type DiscreteDomain <: Domain
  elements::Vector
end

type ContinuousDomain <: Domain
  lower::Real
  upper::Real
end

BinaryDomain() = DiscreteDomain([false, true])

RealDomain() = ContinuousDomain(-Inf, Inf)

type BayesNet
  dag::DAG
  cpds::Vector{CPD}
  index::Dict{NodeName,Int}
  names::Vector{NodeName}
  domains::Vector{Domain}

  function BayesNet(names::Vector{NodeName})
    n = length(names)
    index = [names[i]=>i for i = 1:n]
    cpds = CPD[CPDs.Bernoulli() for i = 1:n]
    domains = Domain[BinaryDomain() for i = 1:n] # default to binary domain
    new(DiGraph(length(names)), cpds, index, names, domains)
  end
end

domain(b::BayesNet, name::NodeName) = b.domains[b.index[name]]

cpd(b::BayesNet, name::NodeName) = b.cpds[b.index[name]]

function parents(b::BayesNet, name::NodeName)
  i = b.index[name]
  NodeName[b.names[j] for j in in_neighbors(b.dag, i)]
end

isValid(b::BayesNet) = !is_cyclic(b.dag)

function hasEdge(bn::BayesNet, sourceNode::NodeName, destNode::NodeName)
    u = bn.index[sourceNode]
    v = bn.index[destNode]
	return has_edge(bn.dag, u, v)
end

function addEdge!(bn::BayesNet, sourceNode::NodeName, destNode::NodeName)
  i = bn.index[sourceNode]
  j = bn.index[destNode]
  add_edge!(bn.dag, i, j)
  bn
end

function removeEdge!(bn::BayesNet, sourceNode::NodeName, destNode::NodeName)
  # it would be nice to use a more efficient implementation
  # see discussion here: https://github.com/JuliaLang/Graphs.jl/issues/73
  # and here: https://github.com/JuliaLang/Graphs.jl/pull/87
  i = bn.index[sourceNode]
  j = bn.index[destNode]
  rem_edge!(bn.dag, i, j)
  bn
end

function addEdges!(bn::BayesNet, pairs)
  for p in pairs
    addEdge!(bn, p[1], p[2])
  end
  bn
end

function removeEdges!(bn::BayesNet, pairs)
  for p in pairs
      removeEdge!(bn, p[1], p[2])
  end
  bn
end

function setDomain!(bn::BayesNet, name::NodeName, dom::Domain)
  i = bn.index[name]
  bn.domains[i] = dom
end

function setCPD!(bn::BayesNet, name::NodeName, cpd::CPD)
  i = bn.index[name]
  bn.cpds[i] = cpd
  bn.domains[i] = domain(cpd)
  nothing
end

function prob(bn::BayesNet, assignment::Assignment)
  prod([pdf(bn.cpds[i], assignment)(assignment[bn.names[i]]) for i = 1:length(bn.names)])
end

include("sampling.jl")


Base.mimewritable(::MIME"image/svg+xml", b::BayesNet) = true

Base.mimewritable(::MIME"text/html", dfs::Vector{DataFrame}) = true

plot(b::BayesNet) = plot(b.dag, ASCIIString[string(s) for s in b.names])

function Base.writemime(f::IO, a::MIME"image/svg+xml", b::BayesNet)
  Base.writemime(f, a, plot(b))
end

function Base.writemime(io::IO, a::MIME"text/html", dfs::Vector{DataFrame})
  for df in dfs
    writemime(io, a, df)
  end
end

include("ndgrid.jl")

function table(bn::BayesNet, name::NodeName)
  edges = in_edges(bn.dag, bn.index[name])
  names = [bn.names[src(e)] for e in edges]
  names = [names, name]
  c = cpd(bn, name)
  d = DataFrame()
  if length(edges) > 0
    A = ndgrid([domain(bn, name).elements for name in names]...)
    i = 1
    for name in names
      d[name] = A[i][:]
      i = i + 1
    end
  else
    d[name] = domain(bn, name).elements
  end
  p = ones(size(d,1))
  for i = 1:size(d,1)
    ownValue = d[i,length(names)]
    a = [names[j]=>d[i,j] for j = 1:(length(names)-1)]
    p[i] = pdf(c, a)(ownValue)
  end
  d[:p] = p
  d
end

table(bn::BayesNet, name::NodeName, a::Assignment) = select(table(bn, name), a)

function *(df1::DataFrame, df2::DataFrame)
  onnames = setdiff(intersect(names(df1), names(df2)), [:p])
  finalnames = vcat(setdiff(union(names(df1), names(df2)), [:p]), :p)
  if isempty(onnames)
    j = join(df1, df2, kind=:cross)
    j[:,:p] .*= j[:,:p_1]
    return j[:,finalnames]
  else
    j = join(df1, df2, on=onnames, kind=:outer)
    j[:,:p] .*= j[:,:p_1]
    return j[:,finalnames]
  end
end

# TODO: this currently only supports binary valued variables
function sumout(a::DataFrame, v::Symbol)
  @assert issubset(unique(a[:,v]), [false, true])
  remainingvars = setdiff(names(a), [v, :p])
  g = groupby(a, v)
  if length(g) == 1
    return a[:,vcat(remainingvars, :p)]
  end
  j = join(g..., on=remainingvars)
  j[:,:p] += j[:,:p_1]
  j[:,vcat(remainingvars, :p)]
end

function sumout(a::DataFrame, v::Vector{Symbol})
  if isempty(v)
    return a
  else
    sumout(sumout(a, v[1]), v[2:end])
  end
end

function normalize(a::DataFrame)
  a[:,:p] /= sum(a[:,:p])
  a
end

function select(t::DataFrame, a::Assignment)
    commonNames = intersect(names(t), keys(a))
    mask = bool(ones(size(t,1)))
    for s in commonNames
        mask &= t[s] .== a[s]
    end
    t[mask, :]
end

function estimate(df::DataFrame)
    n = size(df, 1)
    w = ones(n)
    t = df
    if haskey(df, :p)
        t = df[:, names(t) .!= :p]
        w = df[:p]
    end
    # unique samples
    tu = unique(t)
    # add column with probabilities of unique samples
    tu[:p] = Float64[sum(w[Bool[tu[j,:] == t[i,:] for i = 1:size(t,1)]]) for j = 1:size(tu,1)]
    tu[:p] /= sum(tu[:p])
    tu
end

function estimateConvergence(df::DataFrame, a::Assignment)
    n = size(df, 1)
    p = zeros(n)
    w = ones(n)
    if haskey(df, :p)
        w = df[:p]
    end
    dfindex = find([haskey(a, n) for n in names(df)])
    dfvalues = [a[n] for n in names(df)[dfindex]]'
    cumWeight = 0.
    cumTotalWeight = 0.
    for i = 1:n
        if array(df[i, dfindex]) == dfvalues
            cumWeight += w[i]
        end
        cumTotalWeight += w[i]
        p[i] = cumWeight / cumTotalWeight
    end
    p
end

include("learning.jl")
include("io.jl")

end # module
