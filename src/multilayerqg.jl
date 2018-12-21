module MultilayerQG

export
  fwdtransform!,
  invtransform!,
  streamfunctionfrompv!,
  pvfromstreamfunction!,
  updatevars!,
  set_q!,
  energies


using
  FFTW,
  LinearAlgebra,
  Reexport

@reexport using FourierFlows

using LinearAlgebra: mul!, ldiv!
using FFTW: rfft, irfft
using FourierFlows: getfieldspecs, varsexpression, parsevalsum, parsevalsum2, superzeros

const physicalvars = [:q, :psi, :u, :v]
const fouriervars = [ Symbol(var, :h) for var in physicalvars ]
const forcedfouriervars = cat(fouriervars, [:Fqh], dims=1)

nothingfunction(args...) = nothing

#TODO split given params and computed params, check line 73

abstract type BarotropicParams <: AbstractParams end

struct Params{T} <: AbstractParams
  # prescribed params
  nlayers::Int               # Number of fluid layers
  g::T                       # Gravitational constat
  f0::T                      # Constant planetary vorticity
  beta::T                    # Planetary vorticity y-gradient
  ρ::Array{T,3}              # Array with density of each fluid layer
  H::Array{T,3}              # Array with rest heigh of each fluid layer
  U::Array{T,3}              # Array with imposed constant zonal flow U in each fluid layer
  u::Array{T,3}              # Array with imposed zonal flow u(y) in each fluid layer
  eta::Array{T,2}            # Array containing topographic PV
  mu::T                      # Linear bottom drag
  nu::T                      # Viscosity coefficient
  nnu::Int                   # Hyperviscous order (nnu=1 is plain old viscosity)

  # derived params
  gprime::Array{T,1}         # Array with the reduced gravity constants for each fluid interface
  Qx::Array{T,3}             # Array containing zonal PV gradient due to beta, U, and eta in each fluid layer
  Qy::Array{T,3}             # Array containing meridional PV gradient due to beta, U, and eta in each fluid layer
  S::Array{T,4}              # Array containing coeffients for getting PV from  streamfunction
  invS::Array{T,4}           # Array containing coeffients for inverting PV to streamfunction
  rfftplan::FFTW.rFFTWPlan{Float64,-1,false,3}  # rfft plan for FFTs
  calcFq!::Function          # Function that calculates the forcing on QGPV q
end

struct SinglelayerParams{T} <: BarotropicParams
  # prescribed params
  nlayers::Int               # Number of fluid layers
  g::T                       # Gravitational constat
  f0::T                      # Constant planetary vorticity
  beta::T                       # Planetary vorticity y-gradient
  ρ::Array{T,3}              # Array with density of each fluid layer
  H::Array{T,3}              # Array with rest heigh of each fluid layer
  U::Array{T,3}              # Array with imposed constant zonal flow U in each fluid layer
  u::Array{T,3}              # Array with imposed zonal flow u(y) in each fluid layer
  eta::Array{T,2}              # Array containing topographic PV
  mu::T                      # Linear bottom drag
  nu::T                      # Viscosity coefficient
  nnu::Int                   # Hyperviscous order (nnu=1 is plain old viscosity)

  # derived params
  Qx::Array{T,3}             # Array containing zonal PV gradient due to beta, U, and eta in each fluid layer
  Qy::Array{T,3}             # Array containing meridional PV gradient due to beta, U, and eta in each fluid layer
  rfftplan::FFTW.rFFTWPlan{Float64,-1,false,2}  # rfft plan for FFTs
  calcFq!::Function          # Function that calculates the forcing on QGPV q
end

function Params(nlayers, g, f0, beta, ρ, H, U, u, eta, mu, nu, nnu, grid::AbstractGrid{T}; calcFq=nothingfunction, effort=FFTW.MEASURE) where T

  nkr, nl, ny, nx = grid.nkr, grid.nl,  grid.ny, grid.nx
  kr, l = grid.kr, grid.l

  gprime = g*(ρ[2:nlayers]-ρ[1:nlayers-1]) ./ ρ[1:nlayers-1] # definition to match PYQG
  # gprime = g*(ρ[2:nlayers]-ρ[1:nlayers-1])./ρ[2:nlayers]; #CORRECT DEFINITION
  Fm = @. f0^2 ./ ( gprime*H[2:nlayers  ] ) # m^(-2)
  Fp = @. f0^2 ./ ( gprime*H[1:nlayers-1] ) # m^(-2)

  U = reshape(U, (1,  1, nlayers))
  u = reshape(u, (1, ny, nlayers))

  H = reshape(H, (1,  1, nlayers))
  ρ = reshape(ρ, (1,  1, nlayers))

  #=
  Qy = zeros(1, 1, nlayers)
  Qy[1] = beta - Fp[1]*(U[2]-U[1])
  for j=2:nlayers-1
    Qy[j] = beta - Fp[j]*(U[j+1]-U[j]) - Fm[j-1]*(U[j-1]-U[j])
  end
  Qy[nlayers] = beta - Fm[nlayers-1]*(U[nlayers-1]-U[nlayers])
  =#
  uyy = repeat(irfft( -l.^2 .* rfft(u, [1, 2]),  1, [1, 2]), outer=(1, 1, 1))


  uyy = repeat(uyy, outer=(nx, 1, 1))

  etah = rfft(eta)
  etax = irfft(im*kr.*etah, nx)
  etay = irfft(im*l .*etah, nx)

  Qx = zeros(nx, ny, nlayers)
  @views @. Qx[:, :, nlayers] += etax

  Qy = zeros(nx, ny, nlayers)
  Qy[:, :, 1] = @. beta - uyy[:, :, 1] - Fp[1]*( (u[:, :, 2]+U[2]) - (u[:, :, 1]+U[1]) )
  for j=2:nlayers-1
    Qy[:, :, j] = @. beta - uyy[:, :, j] - Fp[j]*( (u[:, :, j+1]+U[j+1]) - (u[:, :, j]+U[j]) ) - Fm[j-1]*( (u[:, :, j-1]+U[j-1]) - (u[:, :, j]+U[j]) )
  end
  @views Qy[:, :, nlayers] = @. beta - uyy[:, :, nlayers] - Fm[nlayers-1]*( (u[:, :, nlayers-1]+U[nlayers-1]) - (u[:, :, nlayers]+U[nlayers]) )
  @views @. Qy[:, :, nlayers] += etay

  S = Array{Float64}(undef, (nkr, nl, nlayers, nlayers))
  calcS!(S, Fp, Fm, grid)

  invS = Array{Float64}(undef, (nkr, nl, nlayers, nlayers))
  calcinvS!(invS, Fp, Fm, grid)

  rfftplanlayered = plan_rfft(Array{T,3}(undef, grid.nx, grid.ny, nlayers), [1, 2]; flags=effort)

  if nlayers == 1
    SinglelayerParams{T}(nlayers, g, f0, beta, ρ, H, U, u, eta, mu, nu, nnu, Qx, Qy, grid.rfftplan)
  else
    Params{T}(nlayers, g, f0, beta, ρ, H, U, u, eta, mu, nu, nnu, gprime, Qx, Qy, S, invS, rfftplanlayered, calcFq)
  end
end


# ---------
# Equations
# ---------

function Equation(p, g::AbstractGrid{T}; linear=false) where T
  L = Array{Complex{T}}(undef, (g.nkr, g.nl, p.nlayers))
  @. L = - p.nu*g.Krsq^p.nnu
  # [ @views L[:, :, j] = @. - p.nu*g.Krsq^p.nnu + im*p.Qy[j]*g.kr*g.invKrsq for j=1:p.nlayers]
  # @views L[:, :, p.nlayers] .= -p.mu   # bottom linear drag
  @views L[1, 1, :] .= 0
  if linear==true
    FourierFlows.Equation(L, calcNlinear!, g)
  else
    FourierFlows.Equation(L, calcN!, g)
  end
end

function Equation(p::SinglelayerParams, g::AbstractGrid{T}) where T
  L = @. -p.mu - p.nu*g.Krsq^p.nnu + im*p.beta*g.kr*g.invKrsq
  L[1, 1] = 0
  FourierFlows.Equation(L, calcN!, g)
end

# ----
# Vars
# ----

abstract type BarotropicVars <: AbstractVars end

varspecs = cat(
  getfieldspecs(physicalvars, :(Array{T,3})),
  getfieldspecs(fouriervars, :(Array{Complex{T},3})),
  dims=1)

forcedvarspecs = cat(
  getfieldspecs(physicalvars, :(Array{T,3})),
  getfieldspecs(forcedfouriervars, :(Array{Complex{T},3})),
  dims=1)

singlelayervarsspecs = cat(
  getfieldspecs(physicalvars, :(Array{T,2})),
  getfieldspecs(fouriervars, :(Array{Complex{T},2})),
  dims=1)

# Construct Vars types
eval(varsexpression(:Vars, varspecs; parent=:AbstractVars, typeparams=:T))
eval(varsexpression(:ForcedVars, forcedvarspecs; parent=:AbstractVars, typeparams=:T))
eval(varsexpression(:SinglelayerVars, singlelayervarsspecs; parent=:BarotropicVars, typeparams=:T))


"""
    Vars(g)

Returns the vars for unforced multi-layer QG problem with grid g.
"""
function Vars(g::AbstractGrid{T}, p) where T
  @zeros T (g.nx, g.ny, p.nlayers) q psi u v
  @zeros Complex{T} (g.nkr, g.nl, p.nlayers) qh psih uh vh
  Vars(q, psi, u, v, qh, psih, uh, vh)
end

"""
    ForcedVars(g)

Returns the vars for forced multi-layer QG problem with grid g.
"""
function ForcedVars(g::AbstractGrid{T}, p) where T
  v = Vars(g, p)
  Fqh = zeros(Complex{T}, (g.nkr, g.nl, p.nlayers))
  ForcedVars(getfield.(Ref(v), fieldnames(typeof(v)))..., Fqh)
end

function SinglelayerVars(g::AbstractGrid{T}) where T
  @zeros T (g.nx, g.ny) q psi u v
  @zeros Complex{T} (g.nkr, g.nl) qh psih uh vh
  SinglelayerParams(q, psi, u, v, qh, psih, uh, vh)
end



fwdtransform!(varh, var, p::AbstractParams) = mul!(varh, p.rfftplan, var)

invtransform!(var, varh, p::AbstractParams) = ldiv!(var, p.rfftplan, varh)

#=
Array2DOrSubarray = Union{Array{T,2}, SubArray{T,2,Array{T,3},Tuple{Base.Slice{Base.OneTo{Int64}},Base.Slice{Base.OneTo{Int64}},Int64},true}} where T

function fwdtransform!(varh::Array{Complex{T},3}, var::Array{T,3}, g::AbstractGrid{T}) where T
  [ @views fwdtransform!(varh[:, :, j], var[:, :, j], g) for j=1:size(varh, 3) ]
end

invtransform!(var, varh, g::AbstractGrid) = ldiv!(var, g.rfftplan, varh)

function invtransform!(var::Array{T,3}, varh::Array{Complex{T},3}, g::AbstractGrid{T}) where T
  [ @views invtransform!(var[:, :, j], varh[:, :, j], g) for j=1:size(varh, 3) ]
end
=#

function streamfunctionfrompv!(psih, qh, invS, g)
  for j=1:g.nl, i=1:g.nkr
    psih[i, j, :] .= @views invS[i, j, :, :]*qh[i, j, :]
  end
end

function pvfromstreamfunction!(qh, psih, S, g)
  for j=1:g.nl, i=1:g.nkr
    qh[i, j, :] .= @views S[i, j, :, :]*psih[i, j, :]
  end
end

function calcS!(S, Fp, Fm, g)
  F = Matrix(Tridiagonal(Fm, -([Fp; 0] + [0; Fm]), Fp))
  for n=1:g.nl, m=1:g.nkr
    k2 = g.Krsq[m, n]
    Skl = -k2*I + F
    @views S[m, n, :, :] .= Skl
  end
  nothing
end

function calcinvS!(invS, Fp, Fm, g)
  F = Matrix(Tridiagonal(Fm, -([Fp; 0] + [0; Fm]), Fp))
  for n=1:g.nl, m=1:g.nkr
    k2 = g.Krsq[m, n]
    if k2 == 0
      k2 = 1
    end
    Skl = -k2*I + F
    @views invS[m, n, :, :] .= I/Skl
  end
  @views invS[1, 1, :, :] .= 0
  nothing
end


function calcN!(N, sol, t, cl, v, p, g)
  calcN_advection!(N, sol, v, p, g)
  addforcing!(N, sol, t, cl, v, p, g)
  nothing
end

function calcNlinear!(N, sol, t, cl, v, p, g)
  calcN_linearadvection!(N, sol, v, p, g)
  addforcing!(N, sol, t, cl, v, p, g)
  nothing
end

function calcN_advection!(N, sol, v, p, g)
  @. v.qh = sol

  streamfunctionfrompv!(v.psih, v.qh, p.invS, g)

  @. v.uh = -im*g.l *v.psih
  @. v.vh =  im*g.kr*v.psih

  invtransform!(v.u, v.uh, p)
  @. v.u += p.U + p.u                           # add the imposed zonal flow
  @. v.q = v.u*p.Qx
  fwdtransform!(v.uh, v.q, p)
  @. N = -v.uh                                   # -(U+u)*∂Q/∂x

  invtransform!(v.v, v.vh, p)
  @. v.q = v.v*p.Qy
  fwdtransform!(v.vh, v.q, p)
  @. N -= v.vh                                  # -v*∂Q/∂y

  invtransform!(v.q, v.qh, p)

  @. v.u *= v.q # u*q
  @. v.v *= v.q # v*q

  fwdtransform!(v.uh, v.u, p)
  fwdtransform!(v.vh, v.v, p)

  @. N -= im*g.kr*v.uh + im*g.l*v.vh  # -∂[(U+u)q]/∂x-∂[vq]/∂y

  @views @. N[:, :, p.nlayers] += p.mu*g.Krsq*v.psih[:, :, p.nlayers]   # bottom linear drag
end


function calcN_linearadvection!(N, sol, v, p, g)
  @. v.qh = sol
  streamfunctionfrompv!(v.psih, v.qh, p.invS, g)

  @. v.uh = -im*g.l *v.psih
  @. v.vh =  im*g.kr*v.psih

  invtransform!(v.u, v.uh, p)
  invtransform!(v.v, v.vh, p)

  @. v.q = 0
  @views @. v.q[:, :, p.nlayers] = p.eta       # add the topographic PV

  @. v.u *= v.q # u*q
  @. v.v *= v.q # v*q

  fwdtransform!(v.uh, v.u, p)
  fwdtransform!(v.vh, v.v, p)

  @. N = - im*g.kr*v.uh - im*g.l*v.vh   # -∂[ueta]/∂x-∂[veta]/∂y

  invtransform!(v.q, v.qh, p)
  @views @. v.q[:, :, p.nlayers] = p.eta       # add the topographic PV
  @. v.u = p.U + p.u                           # the imposed zonal flow
  @. v.u *= v.q # U*q

  fwdtransform!(v.uh, v.u, p)
  @. N += - im*g.kr*v.uh  # -∂[Uq]/∂x, advection by imposed zonal flow

  @. v.vh =  im*g.kr*v.psih
  invtransform!(v.v, v.vh, p)
  @. v.v *= p.Qy
  fwdtransform!(v.vh, v.v, p)

  @. N -= v.vh                         # -v*∂Q/∂y
  @views @. N[:, :, p.nlayers] += p.mu*g.Krsq*v.psih[:, :, p.nlayers]   # bottom linear drag
end

function addforcing!(N, sol, t, cl, v::ForcedVars, p, g)
  p.calcFq!(v.Fqh, sol, t, cl, v, p, g)
  @. N += v.Fqh
  nothing
end

function updatevars!(prob)
  p, v, g, sol = prob.params, prob.vars, prob.grid, prob.sol
  @. v.qh = sol
  streamfunctionfrompv!(v.psih, v.qh, p.invS, g)
  @. v.uh = -im*g.l*v.psih
  @. v.vh =  im*g.kr*v.psih

  invtransform!(v.q, deepcopy(v.qh), p)
  # @views @. v.q[:, :, p.nlayers] += p.eta
  invtransform!(v.psi, deepcopy(v.psih), p)
  invtransform!(v.u, deepcopy(v.uh), p)
  invtransform!(v.v, deepcopy(v.vh), p)
  nothing
end


function set_q!(prob, q)
  p, v, g, sol = prob.params, prob.vars, prob.grid, prob.sol
  fwdtransform!(v.qh, q, p)
  @. v.qh[1, 1, :] = 0
  @. sol = v.qh

  updatevars!(prob)
  nothing
end


function energies(prob)
  v, p, g, sol = prob.vars, prob.params, prob.grid, prob.sol
  @. v.qh = sol
  streamfunctionfrompv!(v.psih, v.qh, p.invS, g)

  KE, PE = zeros(p.nlayers), zeros(p.nlayers-1)

  @. v.uh = g.Krsq * abs2(v.psih)
  for j=1:p.nlayers
    KE[j] = 1/(2*g.Lx*g.Ly)*parsevalsum(v.uh[:, :, j], g)*p.H[j]/sum(p.H)
  end

  for j=1:p.nlayers-1
    PE[j] = 1/(2*g.Lx*g.Ly)*p.f0^2/p.gprime[j]*parsevalsum(abs2.(v.psih[:, :, j+1].-v.psih[:, :, j]), g)
  end
  # KE, PE
  KE[1]
end

end # module
