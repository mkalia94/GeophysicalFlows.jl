# # Decaying barotropic quasi-geostropic turbulence on a beta-plane
#
# In this example, we simulate an idealized version of the Southern Ocean. The 
# model solves the barotropic quasi-geostrophic eddy dynamics in a flud with 
# variable depth $H-h(x,y)$. We also include an ``ACC'', i.e.,  a domain-average
# zonal velocity $U(t)$ which is forced by constant wind stress $F$ and 
# influenced by bottom drag and topographic form stress. The equations solved are:
# $$\partial_t \nabla^2\psi + \mathsf{J}(\psi-U y, \nabla^2\psi + \beta y + \eta) = -\mu\nabla^2\psi, $$
# $$\partial_t U = F - \mu U -  \langle\psi\partial_x\eta\rangle.$$

using FourierFlows, PyPlot, JLD2, Printf

using FFTW: ifft

import GeophysicalFlows.BarotropicQG
import GeophysicalFlows.BarotropicQG: energy, meanenergy, enstrophy, meanenstrophy


# ## Choosing a device: CPU or GPU

dev = CPU()     # Device (CPU/GPU)
nothing # hide


# ## Numerical parameters and time-stepping parameters
nx  = 256      # 2D resolution = nx^2
stepper = "FilteredETDRK4"   # timestepper
dt  = 2e-2     # timestep
nsteps = 20000 # total number of time-steps
nsubs  = 5000   # number of time-steps for plotting (nsteps must be multiple of nsubs)
nothing # hide


# ## Physical parameters

Lx = 2π        # domain size
 ν = 8.0e-10   # viscosity
nν = 2         # viscosity order
f0 = -1.0      # Coriolis parameter
 β = 1.4015    # the y-gradient of planetary PV
 μ = 1e-2      # linear drag
 F = 0.0012    # normalized wind stress forcing on domain-averaged zonal flow U(t) flow
 nothing # hide

# Topographic PV
topoPV(x, y) = @. 2*cos(10x)*cos(10y)
nothing # hide

# Forcing on the domain-averaged U equation
calcFU(t) = F
nothing # hide


# ## Problem setup
# We initialize a `Problem` by providing a set of keyword arguments. The
# `stepper` keyword defines the time-stepper to be used,
prob = BarotropicQG.Problem(nx=nx, Lx=Lx, f0=f0, β=β, eta=topoPV,
                  calcFU=calcFU, ν=ν, nν=nν, μ=μ, dt=dt, stepper=stepper, dev=dev)
nothing # hide

# and define some shortcuts
sol, cl, v, p, g = prob.sol, prob.clock, prob.vars, prob.params, prob.grid
x, y = gridpoints(g)
nothing # hide


# ## Setting initial conditions

# Our initial condition is simply fluid at rest.
BarotropicQG.set_zeta!(prob, 0*x)


# ## Diagnostics

# Create Diagnostics -- `energy` and `enstrophy` functions are imported at the top.
E = Diagnostic(energy, prob; nsteps=nsteps)
Q = Diagnostic(enstrophy, prob; nsteps=nsteps)
Emean = Diagnostic(meanenergy, prob; nsteps=nsteps)
Qmean = Diagnostic(meanenergy, prob; nsteps=nsteps)
diags = [E, Emean, Q, Qmean]
nothing # hide


# ## Output

# We choose folder for outputing `.jld2` files and snapshots (`.png` files).
filepath = "."
plotpath = "./plots_acctopo"
plotname = "snapshots"
filename = joinpath(filepath, "acctopo.jl.jld2")
nothing # hide

# Do some basic file management
if isfile(filename); rm(filename); end
if !isdir(plotpath); mkdir(plotpath); end
nothing # hide

# And then create Output
get_sol(prob) = sol # extracts the Fourier-transformed solution
get_u(prob) = irfft(im*g.lr.*g.invKrsq.*sol, g.nx)
out = Output(prob, filename, (:sol, get_sol), (:u, get_u))
nothing # hide


# ## Visualizing the simulation

# We define a function that plots the potential vorticity field and the evolution 
# of energy and enstrophy.

function plot_output(prob, fig, axs; drawcolorbar=false)

  sol, v, p, g = prob.sol, prob.vars, prob.params, prob.grid
  BarotropicQG.updatevars!(prob)

  sca(axs[1])
  pcolormesh(x, y, v.q)
  axis("square")
  xlim(0, 2)
  xticks(0:0.5:2)
  ylim(0, 2)
  yticks(0:0.5:2)
  title(L"$\nabla^2\psi + \eta$ (part of the domain)")
  if drawcolorbar==true
    colorbar()
  end

  sca(axs[2])
  cla()
  plot(μ*E.t[1:E.i], E.data[1:E.i], label=L"$E_{\psi}$")
  plot(μ*E.t[1:Emean.i], Emean.data[1:Emean.i], label=L"$E_U$")

  xlabel(L"\mu t")
  ylabel(L"E")
  legend()

  sca(axs[3])
  cla()
  plot(μ*Q.t[1:Q.i], Q.data[1:Q.i], label=L"$Q_{\psi}$")
  plot(μ*Qmean.t[1:Qmean.i], Qmean.data[1:Qmean.i], label=L"$Q_U$")
  xlabel(L"\mu t")
  ylabel(L"Q")
  legend()
end
nothing # hide


# ## Time-stepping the `Problem` forward

# We time-step the `Problem` forward in time.

startwalltime = time()

while cl.step < nsteps
  stepforward!(prob, diags, nsubs)
  
  log = @sprintf("step: %04d, t: %d, E: %.4f, Q: %.4f, walltime: %.2f min",
    cl.step, cl.t, E.data[E.i], Q.data[Q.i], (time()-startwalltime)/60)

  println(log)
end
println("finished")


# ## Plot
# Now let's see what we got. We plot the output,

fig, axs = subplots(ncols=3, nrows=1, figsize=(15, 4))
plot_output(prob, fig, axs; drawcolorbar=true)
gcf() # hide

# and finally save the figure
savename = @sprintf("%s_%09d.png", joinpath(plotpath, plotname), cl.step)
savefig(savename)
