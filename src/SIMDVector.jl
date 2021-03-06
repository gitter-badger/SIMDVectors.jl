immutable SIMDVector{M, N, R, T <: Number} <: AbstractVector{T}
    simd_vecs::NTuple{M, VecRegister{N, T}}
    rest::NTuple{R, T}
end

Base.size{M, N, R}(::SIMDVector{M, N, R}) = (R + M * N,)

@inline function Base.call{M, N, R, T}(::Type{SIMDVector{M, N, R}}, a::Tuple{}, b::NTuple{R, T})
    SIMDVector{M, N, R, T}(a, b)
end

@inline function Base.call{M, N, R, T}(::Type{SIMDVector{M, N, R}}, a::NTuple{M, VecRegister{N, T}}, b::NTuple{R, T})
    SIMDVector{M, N, R, T}(a, b)
end

@inline function Base.call{M, N, R, T}(::Type{SIMDVector{M, N, R}}, a::NTuple{M, VecRegister{N, T}}, b::Tuple{})
    SIMDVector{M, N, R, T}(a, b)
end

# TODO: Try make this more efficient
function Base.getindex{M, N, R}(v::SIMDVector{M, N, R}, i::Int)
    if i > M * N
        @inbounds val = v.rest[i - M*N]
        return val
    else
        # TODO, while loop instead of div
        bucket = div(i-1, N) + 1
        @inbounds val = v.simd_vecs[bucket][i - (bucket-1)*N]
        return val
    end
end

function compute_lengths(N, T)
    if T in VECTOR_DATATYPES
        simd_len = div(VEC_REGISTER_SIZE_BITS , sizeof(T) * 8)
    else # Default to store all other types in the rest field which is a normal tuple
        simd_len = 0
    end

    if simd_len == 0
        rest = N
        buckets = 0
    else
        rest = Int(N % simd_len)
        buckets = div(N - rest, simd_len)
    end

    return simd_len, rest, buckets
end



@generated function load{N}(::Type{SIMDVector{N}}, data, offset::Int = 0)
    T = eltype(data)
    simd_len, rest, buckets = compute_lengths(N, T)

    simd_array_create_expr = Expr(:tuple)
    if simd_len != 0
        for i in 1:simd_len:N-rest
            exp_simd_ele = Expr(:call, :VecRegister)
            push!(exp_simd_ele.args, Expr(:tuple, [:(VecElement(data[$j + offset])) for j in i:simd_len+i-1]...))
            push!(simd_array_create_expr.args, exp_simd_ele)
        end
    end

    rest_array_create_expr = Expr(:tuple, [:(data[$j + offset]) for j in (N-rest+1):N]...)

    return quote
        @assert $N + offset <= length(data)
        @inbounds simd_tup =  $simd_array_create_expr
        @inbounds rest = $rest_array_create_expr
        SIMDVector{$buckets, $simd_len, $rest, $T}(simd_tup, rest)
    end
end

function store!{M, N, R}(data, v::SIMDVector{M,N,R}, offset::Int = 0)
    @assert length(data) + offset >= M*N + R
    c = 1 + offset
    #@inbounds
    for i in 1:M
        simd_element = v.simd_vecs[i]
        @simd for j in 1:N
            data[c] = simd_element[j]
            c += 1
        end
    end

    @simd for i in 1:R
        @inbounds data[c] = v.rest[i]
        c += 1
    end
    return data
end


# Elementwise unary functions
for f in UNARY_FUNCS
    tuple_f_string = symbol(string(f) * "_tuple")
    @eval begin
        @generated function Base.$(f){M, N, R, T}(a::SIMDVector{M, N, R, T})
            ex_simd = vectupexpr(i -> :(($($f))(a.simd_vecs[$i])), M)
            return quote
                SIMDVector{M, N, R}($ex_simd, $($(tuple_f_string))(a.rest))
            end
        end
    end
end

# Binary functions between two vectors and vector, number.
for f in BINARY_FUNCS
    tuple_f_string = symbol(string(f) * "_tuple")
    @eval begin
        @generated function Base.$(f){M, N, R, T <: Number}(a::SIMDVector{M, N, R, T}, b::SIMDVector{M, N, R, T})
            ex_simd = vectupexpr(i -> :(($($f))(a.simd_vecs[$i], b.simd_vecs[$i])), M)
            return quote
                SIMDVector{M, N, R}($ex_simd, $($(tuple_f_string))(a.rest, b.rest))
            end
        end

        @generated function Base.$(f){M, N, R, T <: Number}(a::SIMDVector{M, N, R, T}, b::T)
            ex_simd = vectupexpr(i -> :(($($f))(a.simd_vecs[$i], b)), M)
            return quote
                SIMDVector{M, N, R}($ex_simd, $($(tuple_f_string))(a.rest, b))
            end
        end

        @generated function Base.$(f){M, N, R, T <: Number}(b::T, a::SIMDVector{M, N, R, T})
            ex_simd = vectupexpr(i -> :(($($f))(b, a.simd_vecs[$i])), M)
            return quote
                SIMDVector{M, N, R}($ex_simd, $($(tuple_f_string))(b, a.rest))
            end
        end

        function Base.$(f){M, N, R, T1 <: Number, T2 <: Number}(b::T1, a::SIMDVector{M, N, R, T2})
            $(f)(promote_eltype(b, a)...)
        end

        function Base.$(f){M, N, R, T1 <: Number, T2 <: Number}(a::SIMDVector{M, N, R, T1}, b::T2)
            $(f)(promote_eltype(a, b)...)
        end

        function $(f){M1, N1, R1, T1, M2, N2, R2, T2}(a::SIMDVector{M1, N1, R1, T1},
                                                      b::SIMDVector{M2, N2, R2, T2})
            $(f)(promote(a,b)...)
        end
    end
end

# Reductions
for (f_vec, f_scal) in REDUCTION_FUNCS
    @eval begin
        function $f_vec{M, N, R, T}(v::SIMDVector{M, N, R, T})
            if M == 0
                return $f_vec(v.rest)
            end
            @inbounds v1 = v.simd_vecs[1]
            @inbounds for i in 2:M
                v1 = $f_scal(v1, v.simd_vecs[i])
            end
            if R == 0
                return $f_vec(v1)
            else
                return $f_scal($f_vec(v1), $f_vec(v.rest))
            end
        end
    end
end


@generated function Base.rand{M, N, R, T}(a::Type{SIMDVector{M, N, R, T}})
    ex_simd = SIMDVectors.vectupexpr(i -> :(rand(VecRegister{N, T})), M)
    return quote
        $(Expr(:meta, :inline))
        SIMDVector($ex_simd, rand_tuple(NTuple{R, T}))
    end
end

@generated function Base.zero{M, N, R, T}(a::Type{SIMDVector{M, N, R, T}})
    ex_simd = SIMDVectors.vectupexpr(i -> :z, M)
    return quote
        $(Expr(:meta, :inline))
        z = zero(VecRegister{N, T})
        SIMDVector($ex_simd, zero_tuple(NTuple{R, T}))
    end
end

@generated function Base.one{M, N, R, T}(a::Type{SIMDVector{M, N, R, T}})
    ex_simd = SIMDVectors.vectupexpr(i -> :z, M)
    return quote
        $(Expr(:meta, :inline))
        z = one(VecRegister{N, T})
        SIMDVector($ex_simd, one_tuple(NTuple{R, T}))
    end
end
