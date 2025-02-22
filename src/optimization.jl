export squared_errors, total_squared_errors, optimize_offsets!, optimize_rotations!



"""
    squared_errors(g::BVHGraph, f::Integer)

Calculate the sum of the squared differences between the current and stored positions 
of the vertices for a given frame `f`.

Only those vertices are taken into account that have got positions for every frame.

See also: [`total_squared_errors`](@ref)
"""
squared_errors(g::BVHGraph, f::Integer) = sum(norm(positions(g, v, f) - global_position(g, v, f))^2 for v in filter(v -> size(positions(g, v), 1) == frames(g), vertices(g)))

squared_errors(f::Integer) = g -> squared_errors(g, f)


"""
    total_squared_errors(g::BVHGraph)

Calculate the sum of the squared differences between the current and stored positions 
of the vertices for all frames.

Only those vertices are taken into account that have got positions for every frame.

See also: [`squared_errors`](@ref)
"""
total_squared_errors(g::BVHGraph) = sum(squared_errors(g, f) for f in 1:frames(g))

total_squared_errors() = g -> total_squared_errors(g)


"""
    optimize_offsets!(g::BVHGraph)

For each edge calculate the average norm of the global positions between its source 
and destination, then adjust the offset vector accordingly.

After removing vertices this function can reduce the deviations of the vertices from 
their original global positions since the new offsets are usually biased.

# Examples
```julia
julia> g = load("Example.bvh") |>
           global_positions! |>
           remove_joint!(7) |>
           remove_joint!(13) |>
           remove_joints!("J_L_Bale", "J_R_Bale", "J_L4", "J_L3", "J_L1", "J_T12", "J_T10", "J_T9", "J_T8", "J_T6", "J_T5", "J_T4", "J_T3", "J_T2") |>
           optimize_offsets!
BVHGraph
Name: Example.bvh
[...]
```

See also: [`optimize_rotations!`](@ref), [`total_squared_errors`](@ref)
"""
function optimize_offsets!(g::BVHGraph)
    for v in vertices(g)
        v == 1 && continue
        v₋₁ = inneighbors(g, v)[1]
        o = offset(g, v₋₁, v)
        avg = 0.0

        for f in 1:frames(g)
            d = positions(g, v, f) - positions(g, v₋₁, f)
            avg += norm(d) / frames(g)
        end

        scale = avg / norm(o)
        offset!(g, v₋₁, v, scale * o)
    end

    return g
end

optimize_offsets!() = g -> optimize_offsets!(g)


"""
    optimize_rotations!(g::BVHGraph, optimizer, η::Number, iterations::Integer, exclude::Vector{<:Integer} = Integer[])

Optimize the rotations of each vertex that has got outneighbors and is not in `exclude` 
using a gradient descent algorithm. 

`optimizer` should implement the Flux interface for optimizers. `η` is the learning rate 
and the number of repetitions for each frame is determined by `iterations`. Vertices can 
be excluded from the algorithm by putting them in `exclude`. This can be useful if parts 
of the graph (for example the legs) have not been changed and therefore don't need 
optimization.

# Examples
```julia
julia> g = load("Example.bvh") |>
           global_positions! |>
           remove_joint!(7) |>
           remove_joint!(13) |>
           remove_joints!("J_L_Bale", "J_R_Bale", "J_L4", "J_L3", "J_L1", "J_T12", "J_T10", "J_T9", "J_T8", "J_T6", "J_T5", "J_T4", "J_T3", "J_T2") |>
           optimize_offsets! |>
           optimize_rotations!(ADAM, 0.005, 10, [1, 2, 3, 4, 6, 8, 9, 10, 12, 14])
BVHGraph
Name: Example.bvh
[...]
```

See also: [`optimize_offsets!`](@ref), [`total_squared_errors`](@ref)
"""
function optimize_rotations!(g::BVHGraph, optimizer, η::Number, iterations::Integer, exclude::Vector{<:Integer}=Integer[])
    vinclude = [v for v in filter(v -> v ∉ exclude, vertices(g))]
    vps = [v for v in filter(v -> outneighbors(g, v) != [], vinclude)]

    for f in 1:frames(g)
        original = [positions(g, v, f) for v in vinclude]
        ps = Float64[]
        cs = Float64[]
        syms = Symbol[]
        os = Vector{Float64}[]

        for v in vertices(g)

            if outneighbors(g, v) != []
                list = [deg2rad(θ) for θ in rotations(g, v, f)]
                append!(ps, list)
                append!(cs, list)
                push!(syms, sequence(g, v))
            else
                append!(ps, [0.0, 0.0, 0.0])
                append!(cs, [0.0, 0.0, 0.0])
                push!(syms, :XYZ)
            end

            if v == 1
                push!(os, offset(g))
            else
                v₋₁ = inneighbors(g, v)[1]
                push!(os, offset(g, v₋₁, v))
            end
        end

        pars = Flux.params(ps)

        function calculate_position(v::Integer, N::Matrix{Float64}=Matrix(1.0I, 4, 4))
            if v in vps
                R = rot(syms[v], ps[v*3-2], ps[v*3-1], ps[v*3])
            else
                R = rot(syms[v], cs[v*3-2], cs[v*3-1], cs[v*3])
            end

            if v != 1
                v₋₁ = inneighbors(g, v)[1]
                o = os[v]
                A = [R[1, 1] R[1, 2] R[1, 3] o[1]
                    R[2, 1] R[2, 2] R[2, 3] o[2]
                    R[3, 1] R[3, 2] R[3, 3] o[3]
                    0.0 0.0 0.0 1.0] * N
                return calculate_position(v₋₁, A)
            else
                o = os[v]
                p = positions(g)[f, :]
                A = [R[1, 1] R[1, 2] R[1, 3] p[1]+o[1]
                    R[2, 1] R[2, 2] R[2, 3] p[2]+o[2]
                    R[3, 1] R[3, 2] R[3, 3] p[3]+o[3]
                    0.0 0.0 0.0 1.0] * N
                return A[1:3, 4]
            end
        end

        predict() = [calculate_position(v) for v in vinclude]
        loss() = sum(norm(p - p̂)^2 for (p, p̂) in zip(original, predict()))
        training_loss = loss()
        best_params = pars
        best_loss = training_loss
        opt = optimizer(η)

        for _ in 1:iterations
            gs = Flux.gradient(pars) do
                training_loss = loss()
            end

            if training_loss < best_loss
                best_loss = training_loss
                best_params = pars
            end

            Flux.update!(opt, pars, gs)
        end

        for v in vps
            rotations(g, v)[f, :] = [rad2deg(θ) for θ in best_params[1][v*3-2:v*3]]
        end

        println("Frame: $f \t Loss: $best_loss")
    end

    return g
end

optimize_rotations!(optimizer, η::Number, iterations::Integer, exclude::Vector{<:Integer}=Integer[]) = g -> optimize_rotations!(g, optimizer, η, iterations, exclude)