import itertools,json,math,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT))
from tools.feasibility.momentum_reference import Particle,ZERO_MATRIX,particle_totals,add,cross
from tools.feasibility.mechanics_gpu.reference import mechanics_step
DX=.1;SHAPE=(10,10,10)

def pack(ps):return [[*p.position,p.mass,*p.velocity,0.,*(v for row in p.affine for v in (*row,0.))] for p in ps]
def origin(ps):
 m=math.fsum(p.mass for p in ps)
 return tuple(math.fsum(p.mass*p.position[a] for p in ps)/m for a in range(3))
def build(name,ps,method,g,plane,dt,steps,checkpoints):
 o=origin(ps);initial=particle_totals(ps,DX,o)
 linear=math.fsum(p.mass*math.sqrt(sum(v*v for v in p.velocity)) for p in ps)
 angular=math.fsum(p.mass*math.sqrt(sum((x-y)**2 for x,y in zip(p.position,o)))*math.sqrt(sum(v*v for v in p.velocity)) for p in ps)
 result=dict(name=name,shape=SHAPE,dx=DX,dt=dt,method=method,gravity=g,plane=plane,origin=o,steps=steps,
             initial_particles=pack(ps),initial_totals=initial,linear_scale=linear,angular_scale=angular,snapshots=[])
 accum=[[0.]*4 for _ in range(10)];ticks=0;halt=False;reason=0
 for attempted in range(1,steps+1):
  if not halt:
   ps,ledger,nodes,ok,reason=mechanics_step(ps,DX,SHAPE,dt,method,g,plane,o)
   if ok:
    ticks+=1
    for row in range(9):
     for axis in range(4):accum[row][axis]+=ledger[row][axis]
    accum[9]=ledger[9]
   else:halt=True
  if attempted in checkpoints:result['snapshots'].append(dict(attempted=attempted,ticks=ticks,halted=halt,reason=reason,particles=pack(ps),totals=particle_totals(ps,DX,o),ledger=[list(v) for v in accum]))
 return result
cases=[]
for method in ['pic','apic']:
 ps=[Particle((x,y+.15,z),(.1,0.,.05),.01*(1+(i%5)/5)) for i,(x,y,z) in enumerate(itertools.product((.23,.315,.41),repeat=3))]
 cases.append(build('gravity_'+method,ps,method,(0.,-9.81,0.),None,.001,100,[1,10,100]))
 # The lower cluster carries rigid rotation about its own centre. A flat
 # frictionless plane on a purely translating cluster changes only v_y along y,
 # which the tensor-product stencil transfers with zero angular residual even
 # for PIC; curl inside a particle's support is required for PIC's G2P loss.
 # APIC represents the same rotation through its affine state; PIC cannot.
 ps=[];OMEGA=(0.,0.,5.)
 for ci,center in enumerate([(.27,.23,.315),(.45,.43,.315)]):
  w=OMEGA if ci==0 else (0.,0.,0.)
  affine=((0.,-w[2],w[1]),(w[2],0.,-w[0]),(-w[1],w[0],0.)) if method=='apic' else ZERO_MATRIX
  for offset in itertools.product((-.005,.005),repeat=3):
   i=len(ps);ps.append(Particle(tuple(a+b for a,b in zip(center,offset)),add((.1,-.25,0.),cross(w,offset)),.01+.002*(i%3),affine))
 cases.append(build('plane_'+method,ps,method,(0.,0.,0.),.2,.002,20,[1,5,20]))
 if method=='apic':cases.append(build('rejected_plane_apic',ps,method,(0.,0.,0.),.2,.5,3,[1,3]))
path=ROOT/'tests/feasibility/mechanics_gpu/cases.json';path.write_text(json.dumps(dict(cases=cases),indent=2)+'\n');print(path)
for c in cases:
 print(c['name'], 'accepted',c['snapshots'][-1]['ticks'],'halt',c['snapshots'][-1]['halted'])
