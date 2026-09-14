import itertools
import json
import math
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))
from tools.feasibility.momentum_reference import (Particle,ZERO,ZERO_MATRIX,add,matvec,sub,particle_totals,grid_totals)
from tools.feasibility.momentum_gpu.reference import step

DX=.1
SHAPE=(10,10,10)
ROT=((0.,-2.,0.),(2.,0.,0.),(0.,0.,0.))
AFF=((-0.2,-2.,.3),(2.,.1,-1.),(-.4,.5,.3))

def cloud(matrix=ZERO_MATRIX,translation=(.15,-.05,.08),method='apic',nonaffine=False):
    positions=list(itertools.product((.23,.315,.41),repeat=3))
    masses=[.01*(1+(i%5)/5) for i in range(27)]
    center=tuple(math.fsum(m*x[a] for m,x in zip(masses,positions))/math.fsum(masses) for a in range(3))
    result=[]
    for i,(x,m) in enumerate(zip(positions,masses)):
        v=add(translation,matvec(matrix,sub(x,center)))
        c=matrix if method=='apic' else ZERO_MATRIX
        if nonaffine:
            v=(.3*math.sin(i*1.7),.3*math.cos(i*.9),.3*math.sin(i*.6)+.05)
            if method=='apic': c=tuple(tuple(k*math.cos(i*.3) for k in row) for row in matrix)
        result.append(Particle(x,v,m,c))
    return result,center

def packed(particles):
    return [[*p.position,p.mass,*p.velocity,0.,*(x for row in p.affine for x in (*row,0.))] for p in particles]

def build_case(name,particles,origin,method,dt,steps,checkpoints):
    initial=particle_totals(particles,DX,origin)
    linear_scale=math.fsum(p.mass*math.sqrt(sum(v*v for v in p.velocity)) for p in particles)
    angular_scale=math.fsum(p.mass*(math.sqrt(sum(x*x for x in sub(p.position,origin)))*math.sqrt(sum(v*v for v in p.velocity))
                    +DX*DX/4*math.sqrt(sum(x*x for row in p.affine for x in row))) for p in particles)
    result=dict(name=name,shape=SHAPE,dx=DX,dt=dt,method=method,steps=steps,origin=origin,
                initial_particles=packed(particles),initial_totals=initial,linear_scale=linear_scale,angular_scale=angular_scale,snapshots=[])
    ticks=0;halted=False
    for attempted in range(1,steps+1):
        if not halted:
            particles,grid,accepted=step(particles,DX,SHAPE,dt,method)
            if accepted:ticks+=1
            else:halted=True
        if attempted in checkpoints:
            result['snapshots'].append(dict(attempted=attempted,ticks=ticks,halted=halted,particles=packed(particles),totals=particle_totals(particles,DX,origin)))
    return result

cases=[]
for method in ['pic','apic']:
    p,o=cloud(method=method)
    cases.append(build_case('translation_'+method,p,o,method,.002,100,[1,10,100]))
    p,o=cloud(ROT,ZERO,method)
    cases.append(build_case('rotation_'+method,p,o,method,.002,100,[1,10,100]))
    p,o=cloud(AFF,ZERO,method,True)
    cases.append(build_case('nonaffine_'+method,p,o,method,.001,100,[1,10,100]))
p,o=cloud(AFF,(.1,-.05,.02),'apic')
cases.append(build_case('affine_apic',p,o,'apic',.002,100,[1,10,100]))
p=[Particle((.823,.3,.3),(.1,0.,0.),.01),Particle((.3,.3,.3),(.02,0.,0.),.02)]
cases.append(build_case('boundary_atomic_apic',p,(0.,0.,0.),'apic',.1,5,[1,2,3,5]))
path=ROOT/'tests/feasibility/momentum_gpu/cases.json'
path.write_text(json.dumps(dict(cases=cases),indent=2)+'\n')
print(path)
