"""
The geometry consists of a “hook” in the form of a curved strip rigidly clamped
at one end and loaded with a unit in-plane shear along the width at the other
end. It has two circular segments that are connected at the tangent point. The
smaller segment has a mean radius of 0.3556 m (14 inches) and spans 60° from
the clamped end to the tangent point. The larger segment spans 150° from the
tangent point to the free end and has a mean radius of 1.1684 m (46 inches).
The hook is 0.0508 m (2 inches) thick and 0.508 m (20 inches) wide, modeled as
linear elastic with an elastic modulus of 22.77 MPa (3300 psi) and a Poisson's
ratio of 0.35. In most tests the shear force is applied through the use of a
distributing coupling constraint. The coupling constraint provides coupling
between a reference node on which the load is prescribed and the nodes located
on the free end. The distributed nodal loads on the free end are equivalent to
a uniformly distributed load of 8.7563 N/m (0.05 lb/in). In two of the tests an
equivalent shear force is applied as a distributed shear traction instead.


"""
module raasch_examples

using LinearAlgebra
using FinEtools
using FinEtoolsDeforLinear
using FinEtoolsFlexStructures.FESetShellT3Module: FESetShellT3
using FinEtoolsFlexStructures.FESetShellQ4Module: FESetShellQ4
using FinEtoolsFlexStructures.FEMMShellT3FFModule
using T3FF_Verification.FEMMShellT3DSGMTModule
using FinEtoolsFlexStructures.RotUtilModule: initial_Rfield, linear_update_rotation_field!, update_rotation_field!
using FinEtoolsFlexStructures.VisUtilModule: plot_nodes, plot_midline, render, plot_space_box, plot_midsurface, space_aspectratio, save_to_json

using Infiltrator

function _execute(input = "raasch_s4_1x9.inp", drilling_stiffness_scale = 1.0, visualize = true)
    E = 3300.0;
    nu = 0.35;
    thickness  =  2.0;
    tolerance = thickness/2
    # analytical solution for the vertical deflection under the load
    analyt_sol = 5.02;
    R = 46.0;
    formul = FEMMShellT3FFModule
    formul = FEMMShellT3DSGMTModule
    @show formul

    output = import_ABAQUS(joinpath(dirname(@__FILE__()), input))
    fens = output["fens"]
    fes = output["fesets"][1]

    connected = findunconnnodes(fens, fes);
    fens, new_numbering = compactnodes(fens, connected);
    fes = renumberconn!(fes, new_numbering);

    fens, fes = Q4toT3(fens, fes)

    @show count(fens)

    # plots = cat(plot_space_box([[0 0 -R/2]; [R/2 R/2 R/2]]),
    #     plot_nodes(fens),
    #     plot_midsurface(fens, fes);
    # dims = 1)
    # pl = render(plots)

    mater = MatDeforElastIso(DeforModelRed3D, E, nu)
    
        # Report
    
    @info "Mesh: $input"

    sfes = FESetShellT3()
    accepttodelegate(fes, sfes)
    femm = formul.make(IntegDomain(fes, TriRule(1), thickness), mater)
    femm.drilling_stiffness_scale = drilling_stiffness_scale
    stiffness = formul.stiffness
    associategeometry! = formul.associategeometry!

    # Construct the requisite fields, geometry and displacement
    # Initialize configuration variables
    geom0 = NodalField(fens.xyz)
    u0 = NodalField(zeros(size(fens.xyz,1), 3))
    Rfield0 = initial_Rfield(fens)
    dchi = NodalField(zeros(size(fens.xyz,1), 6))

    # Apply EBC's
    # Clamped end
    l1 = selectnode(fens; box = Float64[0 0 -Inf Inf -Inf Inf], inflate = tolerance)
    for i in [1,2,3,4,5,6]
        setebc!(dchi, l1, true, i)
    end
    
    applyebc!(dchi)
    numberdofs!(dchi);

    # Assemble the system matrix
    associategeometry!(femm, geom0)
    K = stiffness(femm, geom0, u0, Rfield0, dchi);

    # Load
    bfes = meshboundary(fes)
    l1 = selectelem(fens, bfes, box = [97.9615 97.9615 -16 -16 0 20], inflate = tolerance)
    lfemm = FEMMBase(IntegDomain(subset(bfes, l1), GaussRule(1, 2)))
    fi = ForceIntensity(FFlt[0, 0, 0.05, 0, 0, 0]);
    F = distribloads(lfemm, geom0, dchi, fi, 3);
    
    # @infiltrate
    # Solve
    U = K\F
    scattersysvec!(dchi, U[:])
    nl = selectnode(fens; box = Float64[97.9615 97.9615 -16 -16 0 0], inflate = tolerance)
    targetu =  dchi.values[nl, 3][1]
    @info "Solution: $(round(targetu, digits=8)),  $(round(targetu/analyt_sol, digits = 4)*100)%"

    # Visualization
    if visualize
        scattersysvec!(dchi, (R/2)/maximum(abs.(U)).*U)
        update_rotation_field!(Rfield0, dchi)
        plots = cat(plot_space_box([[0 0 -R]; [R R R]]),
            plot_nodes(fens),
            plot_midsurface(fens, fes; x = geom0.values, u = dchi.values[:, 1:3], R = Rfield0.values);
            dims = 1)
        pl = render(plots)
    end
    return targetu/analyt_sol
end

function test_convergence()
    
    @info "Raasch hook"

    for m in ["1x9", "3x18", "5x36", "10x72"]
    # for m in ["1x9", ]
        _execute("raasch_s4_" * m * ".inp", 1.0, false)
    end
    return true
end

function test_dep_drilling_stiffness_scale()
    
    @info "Raasch hook"

    all_results = []
    all_drilling_stiffness_scale = [1000.0, 1.0, 0.1, 0.0001, 0.000001] 
    for drilling_stiffness_scale in all_drilling_stiffness_scale
        results = Float64[]
        for m in ["1x9", "3x18", "5x36", "10x72"]
    # for m in ["1x9", ]
            v = _execute("raasch_s4_" * m * ".inp", drilling_stiffness_scale, false)
            push!(results, v)
        end
        push!(all_results, results)
    end
    return all_drilling_stiffness_scale, all_results
end

end # module

using .raasch_examples
raasch_examples.test_convergence()
all_drilling_stiffness_scale, all_results = raasch_examples.test_dep_drilling_stiffness_scale()


using PGFPlotsX

objects = []

ns = [20, 76, 222, 803]

styles = ["solid", "dashed", "dotted", "dashdotted", "densely dotted"]

for (drilling_stiffness_scale, results, style) in zip(all_drilling_stiffness_scale, all_results, styles)
    @pgf p = PGFPlotsX.Plot(
    {
    color = "black",
    line_width  = 0.7, 
    style = style,
    },
    Coordinates([v for v in  zip(ns, results)])
    )
    push!(objects, p)
    push!(objects, LegendEntry("$drilling_stiffness_scale"))
end

@pgf ax = Axis(
    {
        xlabel = "Number of Nodes [ND]",
        ylabel = "Normalized Displacement [ND]",
        # xmin = range[1],
        # xmax = range[2],
        xmode = "log", 
        ymode = "linear",
        yminorgrids = "true",
        grid = "both",
        legend_style = {
            at = Coordinate(0.5, 1.05),
            anchor = "south",
            legend_columns = -1
        },
    },
    objects...
)

display(ax)
pgfsave("raasch_examples-dependence-on-drilling_stiffness_scale.pdf", ax)
