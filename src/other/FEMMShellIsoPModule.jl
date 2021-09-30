module FEMMShellIsoPModule

using LinearAlgebra: norm, Transpose, mul!, diag, rank, eigen
using Statistics: mean
using FinEtools
import FinEtools.FESetModule: gradN!, nodesperelem, manifdim
using FinEtools.IntegDomainModule: IntegDomain, integrationdata, Jacobianvolume
using FinEtoolsDeforLinear.MatDeforLinearElasticModule: tangentmoduli!, update!, thermalstrain!
using FinEtools.MatrixUtilityModule: add_btdb_ut_only!, complete_lt!, locjac!, add_nnt_ut_only!, add_btsigma!
using FinEtoolsFlexStructures.FESetShellT3Module: FESetShellT3, local_frame!


const __ndof = 6 # number of degrees of freedom per node

"""
    FEMMShellIsoP{S<:AbstractFESet, F<:Function} <: AbstractFEMM

Class for plain-vanilla isoparametric flat shell triangle
finite element modeling machine.

BEWARE: Not finished yet.
"""
mutable struct FEMMShellIsoP{S<:AbstractFESet, F<:Function, M} <: AbstractFEMM
    integdomain::IntegDomain{S, F} # integration domain data
    material::M # material object
    _associatedgeometry::Bool
    _normals::FFltMat
    # The attributes below are buffers used in various operations.
    _loc::FFltMat
    _J::FFltMat
    _J0::FFltMat
    _ecoords0::FFltMat
    _ecoords1::FFltMat
    _edisp1::FFltMat
    _evel1::FFltMat
    _evel1f::FFltMat
    _lecoords0::FFltMat
    _dofnums::FIntMat
    _F0::FFltMat
    _Ft::FFltMat
    _FtI::FFltMat
    _FtJ::FFltMat
    _Te::FFltMat
    _tempelmat1::FFltMat
    _tempelmat2::FFltMat
    _tempelmat3::FFltMat
    _elmat::FFltMat
    _elmatTe::FFltMat
    _elmato::FFltMat
    _elvec::FFltVec
    _elvecf::FFltVec
    _lloc::FFltMat
    _lJ::FFltMat
    _lgradN::FFltMat
    _Bm::FFltMat
    _Bb::FFltMat
    _Bs::FFltMat
    _DpsBmb::FFltMat
    _DtBs::FFltMat
    _LF::FFltVec
    _RI::FFltMat
    _RJ::FFltMat
    _OS::FFltMat
end

function FEMMShellIsoP(integdomain::IntegDomain{S, F}, material::M) where {S<:AbstractFESet, F<:Function, M}
    _nnmax = 0
    for j in 1:count(integdomain.fes)
        _nnmax = max(_nnmax, maximum(integdomain.fes.conn[j]))
    end
    # Allocate buffers
    __nn = nodesperelem(integdomain.fes) # number of nodes
    _normals = fill(0.0, _nnmax, 3)
    _loc = fill(0.0, 1, 3)
    _J = fill(0.0, 3, 2)
    _J0 = fill(0.0, 3, 2)
    _ecoords0 = fill(0.0, __nn, 3); 
    _ecoords1 = fill(0.0, __nn, 3)
    _edisp1 = fill(0.0, __nn, 3); 
    _evel1 = fill(0.0, __nn, __ndof); 
    _evel1f = fill(0.0, __nn, __ndof)
    _lecoords0 = fill(0.0, __nn, 2) 
    _dofnums = zeros(FInt, 1, __nn*__ndof); 
    _F0 = fill(0.0, 3, 3); 
    _Ft = fill(0.0, 3, 3); 
    _FtI = fill(0.0, 3, 3); 
    _FtJ = fill(0.0, 3, 3)
    _Te = fill(0.0, __nn*__ndof, __nn*__ndof)
    _tempelmat1 = fill(0.0, __nn*__ndof, __nn*__ndof); 
    _tempelmat2 = fill(0.0, __nn*__ndof, __nn*__ndof); 
    _tempelmat3 = fill(0.0, __nn*__ndof, __nn*__ndof)
    _elmat = fill(0.0, __nn*__ndof, __nn*__ndof);    
    _elmatTe = fill(0.0, __nn*__ndof, __nn*__ndof);    
    _elmato = fill(0.0, __nn*__ndof, __nn*__ndof)
    _elvec = fill(0.0, __nn*__ndof);    
    _elvecf = fill(0.0, __nn*__ndof)
    _lloc = fill(0.0, 1, 2)
    _lJ = fill(0.0, 2, 2)
    _lgradN = fill(0.0, __nn, 2)
    _Bm = fill(0.0, 3, __nn*__ndof)
    _Bb = fill(0.0, 3, __nn*__ndof)
    _Bs = fill(0.0, 2, __nn*__ndof)
    _DpsBmb = similar(_Bm)
    _DtBs = similar(_Bs)
    _LF = fill(0.0, __nn*__ndof)
    _RI = fill(0.0, 3, 3);    
    _RJ = fill(0.0, 3, 3);    
    _OS = fill(0.0, 3, 3)
    return FEMMShellIsoP(integdomain, material,
        false,
        _normals,
        _loc, _J, _J0,
        _ecoords0, _ecoords1, _edisp1, _evel1, _evel1f, _lecoords0,
        _dofnums, 
        _F0, _Ft, _FtI, _FtJ, _Te,
        _tempelmat1, _tempelmat2, _tempelmat3, _elmat, _elmatTe, _elmato, 
        _elvec, _elvecf, 
        _lloc, _lJ, _lgradN,
        _Bm, _Bb, _Bs, _DpsBmb, _DtBs, _LF, 
        _RI, _RJ, _OS)
end

function make(integdomain, material)
    return FEMMShellIsoP(integdomain, material)
end

function _compute_J0!(J0, ecoords)
    x, y, z = ecoords[2, :].-ecoords[1, :]
    J0[:, 1] .= (x, y, z)
    x, y, z = ecoords[3, :].-ecoords[1, :]
    J0[:, 2] .= (x, y, z)
end
    
function _shell_material_stiffness(material)
    D = fill(0.0, 6, 6)
    t::FFlt, dt::FFlt, loc::FFltMat, label::FInt = 0.0, 0.0, [0.0 0.0 0.0], 0
    tangentmoduli!(material,  D,  t, dt, loc, label)
    Dps = fill(0.0, 3, 3)
    Dps[1:2, 1:2] = D[1:2, 1:2] -  (reshape(D[1:2,3], 2, 1) * reshape(D[3,1:2], 1, 2))/D[3, 3]
    ix=[1, 2, 4];
    for i = 1:3
        Dps[3,i] = Dps[i,3] = D[4, ix[i]];
    end
    Dt = fill(0.0, 2, 2)
    ix=[5, 6];
    for i = 1:2
        Dt[i,i] = D[ix[i], ix[i]];
    end
    return Dps, Dt
end

function _transfmat!(Te, __nn, Ft)
    for i in 1:2*__nn
        r = (i-1)*3 .+ (1:3)
        @. Te[r, r] = Ft
    end
    return Te
end

function _projmat!(Te, __nn, ln)
    Te .= 0.0
    for _j in 1:size(Te, 1)
        Te[_j, _j] = 1.0
    end
    for w in 1:__nn
        r = (w-1)*6+4:(w-1)*6+6 
        Te[r, r] .-= ln[w] * ln[w]'
    end
    return Te
end

"""
    _Bsmat!(Bs, gradN, N)

Compute the linear transverse shear strain-displacement matrix.
"""
function _Bsmat!(Bs, gradN, N)
    __nn = size(gradN, 1) 
    for i in 1:__nn
        Bs[1,6*(i-1)+3] = gradN[i,1];
        Bs[1,6*(i-1)+5] = N[i];
        Bs[2,6*(i-1)+3] = gradN[i,2];
        Bs[2,6*(i-1)+4] = -N[i];
    end
end

"""
    _Bmmat!(Bm, gradN)

Compute the linear membrane strain-displacement matrix.
"""
function _Bmmat!(Bm, gradN)
    __nn = size(gradN, 1) 
    for i in 1:__nn
        Bm[1,6*(i-1)+1] = gradN[i,1];
        Bm[2,6*(i-1)+2] = gradN[i,2];
        Bm[3,6*(i-1)+1] = gradN[i,2];
        Bm[3,6*(i-1)+2] = gradN[i,1];
    end
end

"""
    _Bbmat!(Bb, gradN)

Compute the linear, displacement independent, curvature-displacement/rotation matrix for a shell quadrilateral element with nfens=3 nodes. Displacements and rotations are in a local coordinate system.
"""
function _Bbmat!(Bb, gradN)
    __nn = size(gradN, 1) 
    for i in 1:__nn
        Bb[1,6*(i-1)+5] = gradN[i,1];
        Bb[2,6*(i-1)+4] = -gradN[i,2];
        Bb[3,6*(i-1)+4] = -gradN[i,1];
        Bb[3,6*(i-1)+5] = gradN[i,2];
    end
end

function associategeometry!(self::FEMMShellIsoP,  geom::NodalField{FFlt})
    J0 = self._J0
    F0 = self._F0
    normals = self._normals
    # Compute the normals at the nodes
    for el in 1:count(self.integdomain.fes)
        i, j, k = self.integdomain.fes.conn[el]
        J0[:, 1] = geom.values[j, :] - geom.values[i, :]
        J0[:, 2] = geom.values[k, :] - geom.values[i, :]
        local_frame!(delegateof(self.integdomain.fes), F0, J0)
        for n in self.integdomain.fes.conn[el]
            normals[n, :] .+= F0[:, 3]
        end
    end
    for j in 1:size(normals, 1)
        nn = norm(normals[j, :])
        if nn > 0.0
            normals[j, :] ./= nn
        end
    end
    self._associatedgeometry = true
    return self
end

"""
    stiffness(self::FEMMShellIsoP, assembler::ASS, geom0::NodalField{FFlt}, u1::NodalField{T}, Rfield1::NodalField{T}, dchi::NodalField{T}) where {ASS<:AbstractSysmatAssembler, T<:Number}

Compute the material stiffness matrix.
"""
function stiffness(self::FEMMShellIsoP, assembler::ASS, geom0::NodalField{FFlt}, u1::NodalField{T}, Rfield1::NodalField{T}, dchi::NodalField{TI}) where {ASS<:AbstractSysmatAssembler, T<:Number, TI<:Number}
    @assert self._associatedgeometry == true
    fes = self.integdomain.fes
    __nn = nodesperelem(self.integdomain.fes) # number of nodes
    npts,  Ns,  gradNparams,  w,  pc = integrationdata(self.integdomain);
    normals = self._normals
    loc, J, J0 = self._loc, self._J, self._J0
    ecoords0, ecoords1, edisp1, dofnums = self._ecoords0, self._ecoords1, self._edisp1, self._dofnums
    lecoords0 = self._lecoords0
    F0, Ft, FtI, FtJ, Te = self._F0, self._Ft, self._FtI, self._FtJ, self._Te
    R1I, R1J = self._RI, self._RJ
    elmat, elmatTe = self._elmat, self._elmatTe
    lloc, lJ, lgradN = self._lloc, self._lJ, self._lgradN 
    Bm, Bb, Bs, DpsBmb, DtBs = self._Bm, self._Bb, self._Bs, self._DpsBmb, self._DtBs
    Dps, Dt = _shell_material_stiffness(self.material)
    scf=5/6;  # shear correction factor
    Dt .*= scf
    ln = [vec(fill(0.0, 3)) for di in 1:__nn]
    startassembly!(assembler, size(elmat, 1), size(elmat, 2), count(fes), dchi.nfreedofs, dchi.nfreedofs);
    for i in 1:count(fes) # Loop over elements
        gathervalues_asmat!(geom0, ecoords0, fes.conn[i]);
        gathervalues_asmat!(u1, edisp1, fes.conn[i]);
        ecoords1 .= ecoords0 .+ edisp1
        _compute_J0!(J0, ecoords0)
        local_frame!(delegateof(fes), Ft, J0)
        mul!(lecoords0, ecoords0, view(Ft, :, 1:2))
        fill!(elmat,  0.0); # Initialize element matrix
        for j in 1:npts
            locjac!(loc, J, ecoords0, Ns[j], gradNparams[j])
            Jac = Jacobiansurface(self.integdomain, J, loc, fes.conn[i], Ns[j]);
            t = self.integdomain.otherdimension(loc, fes.conn[i], Ns[j])
            locjac!(lloc, lJ, lecoords0, Ns[j], gradNparams[j])
            gradN!(fes, lgradN, gradNparams[j], lJ);
            _Bmmat!(Bm, lgradN)
            _Bbmat!(Bb, lgradN)
            _Bsmat!(Bs, lgradN, Ns[j])
            add_btdb_ut_only!(elmat, Bm, t*Jac*w[j], Dps, DpsBmb)
            add_btdb_ut_only!(elmat, Bb, (t^3)/12*Jac*w[j], Dps, DpsBmb)
            # The stabilization expression has a huge effect (at least for the
            # pinched cylinder). What is the recommended multiplier of he^2?
            # he = sqrt(Jac)
            # add_btdb_ut_only!(elmat, Bs, 10000000*(t^3/(t^2+0.2*he^2))*Jac*w[j], Dt, DtBs)
            add_btdb_ut_only!(elmat, Bs, t*Jac*w[j], Dt, DtBs)
        end
        complete_lt!(elmat)
         # Project out contributions to moments in the normal direction (drilling)
        for di in 1:__nn
            ln[di] .= Ft'*vec(normals[fes.conn[i][di],:])
        end
        _projmat!(Te, __nn, ln)
        mul!(elmatTe, elmat, Transpose(Te))
        mul!(elmat, Te, elmatTe)
        # @show eigen(elmat).values
        # @show eigen(elmat).values
        # Apply drilling-rotation artificial stiffness
        kavg = 0.0
        for di in 4:__ndof:__nn*__ndof
            kavg += elmat[di, di]
            kavg += elmat[di+1, di+1]
        end
        kavg = kavg / 1e-4
        for di in 1:__nn
            r = (di-1)*__ndof+4:(di-1)*__ndof+6
            elmat[r, r] .+= kavg .* ln[di]*ln[di]'
        end   
        complete_lt!(elmat)
        # @show eigen(elmat).values
        # Transformation into global ordinates
        _transfmat!(Te, __nn, Ft)
        mul!(elmatTe, elmat, Transpose(Te))
        mul!(elmat, Te, elmatTe)    
        # Assembly
        gatherdofnums!(dchi, dofnums, fes.conn[i]); 
        assemble!(assembler, elmat, dofnums, dofnums); 
    end # Loop over elements
    return makematrix!(assembler);
end

function stiffness(self::FEMMShellIsoP, geom0::NodalField{FFlt}, u1::NodalField{T}, Rfield1::NodalField{T}, dchi::NodalField{TI}) where {T<:Number, TI<:Number}
    assembler = SysmatAssemblerSparseSymm();
    return stiffness(self, assembler, geom0, u1, Rfield1, dchi);
end


"""
    mass(self::FEMMShellIsoP,  assembler::A,  geom::NodalField{FFlt}, dchi::NodalField{T}) where {A<:AbstractSysmatAssembler, T<:Number}

Compute the consistent mass matrix

This is a general routine for the shell FEMM.
"""
function mass(self::FEMMShellIsoP,  assembler::A,  geom0::NodalField{FFlt}, dchi::NodalField{T}) where {A<:AbstractSysmatAssembler, T<:Number}
    fes = self.integdomain.fes
    __nn = nodesperelem(self.integdomain.fes) # number of nodes
    npts,  Ns,  gradNparams,  w,  pc = integrationdata(self.integdomain);
    loc, J, J0 = self._loc, self._J, self._J0
    ecoords0, ecoords1, edisp1, dofnums = self._ecoords0, self._ecoords1, self._edisp1, self._dofnums
    lecoords0 = self._lecoords0
    F0, Ft, FtI, FtJ, Te = self._F0, self._Ft, self._FtI, self._FtJ, self._Te
    R1I, R1J = self._RI, self._RJ
    elmat, elmatTe = self._elmat, self._elmatTe
    lloc, lJ, lgradN = self._lloc, self._lJ, self._lgradN 
    rho::FFlt = massdensity(self.material); # mass density
    tmss = fill(0.0, __nn);# basis f. matrix -- buffer
    rmss = fill(0.0, __nn);# basis f. matrix -- buffer
    ndn = ndofs(dchi)
    startassembly!(assembler,  size(elmat,1),  size(elmat,2),  count(fes), dchi.nfreedofs,  dchi.nfreedofs);
    for i = 1:count(fes) # Loop over elements
        gathervalues_asmat!(geom0, ecoords0, fes.conn[i]);
        _compute_J0!(J0, ecoords0)
        local_frame!(delegateof(fes), Ft, J0)
        fill!(tmss, 0.0)
        fill!(rmss, 0.0)
        # Compute the translational and rotational masses corresponding to nodes
        for j = 1:npts # Loop over quadrature points
            locjac!(loc, J, ecoords0, Ns[j], gradNparams[j])
            Jac = Jacobiansurface(self.integdomain, J, loc, fes.conn[i], Ns[j]);
            t = self.integdomain.otherdimension(loc, fes.conn[i], Ns[j])
            mul!(lecoords0, ecoords0, view(Ft, :, 1:2))
            tfactor = rho*(t*Jac*w[j]);
            rfactor = rho*(t^3/12*Jac*w[j]);
            for k in 1:__nn
                tmss[k] += tfactor*(Ns[j][k])
                rmss[k] += rfactor*(Ns[j][k])
            end
        end # Loop over quadrature pointsnd
        fill!(elmat,  0.0); # Initialize element matrix
        for k in 1:__nn
            for d in 1:3
                c = (k - 1) * __ndof + d
                elmat[c, c] += tmss[k]
            end
            for d in 4:5
                c = (k - 1) * __ndof + d
                elmat[c, c] += rmss[k]
            end
            d = 6
            c = (k - 1) * __ndof + d
            elmat[c, c] += rmss[k] / 1e6
        end
        # Transformation into global ordinates
        _transfmat!(__nn, Te, Ft)
        mul!(elmatTe, elmat, Transpose(Te))
        mul!(elmat, Te, elmatTe)
        # Assemble
        gatherdofnums!(dchi,  dofnums,  fes.conn[i]);# retrieve degrees of freedom
        assemble!(assembler,  elmat,  dofnums,  dofnums);# assemble symmetric matrix
    end # Loop over elements
    return makematrix!(assembler);
end

function mass(self::FEMMShellIsoP,  geom::NodalField{FFlt},  u::NodalField{T}) where {T<:Number}
    assembler = SysmatAssemblerSparseSymm();
    return mass(self, assembler, geom, u);
end

end # module

