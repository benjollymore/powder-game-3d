"""Apply the predeclared FP32 motion criteria; do not rebaseline failures."""
import json
import math
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))
from tools.feasibility.momentum_reference import Particle,Node,particle_totals,grid_totals,sub
EVIDENCE=ROOT/'docs/milestone/evidence-momentum-gpu'

def norm(v):return math.sqrt(math.fsum(x*x for x in v))
def unpack(flat):
    if len(flat)%20 or not all(math.isfinite(x) for x in flat):raise ValueError('Invalid particle record')
    return [Particle(tuple(flat[i:i+3]),tuple(flat[i+4:i+7]),flat[i+3],tuple(tuple(flat[i+j:i+j+3]) for j in [8,12,16])) for i in range(0,len(flat),20)]
def grid_unpack(flat,shape):
    if len(flat)!=math.prod(shape)*4 or not all(math.isfinite(x) for x in flat):raise ValueError('Invalid grid record')
    nx,ny,nz=shape
    return {(i%nx,(i//nx)%ny,i//(nx*ny)):Node(flat[i*4+3],tuple(flat[i*4:i*4+3]))
            for i in range(nx*ny*nz) if flat[i*4+3]>0}

fixtures=json.loads((ROOT/'tests/feasibility/momentum_gpu/cases.json').read_text())['cases']
actual=json.loads((EVIDENCE/'results.json').read_text())
failures=[];metrics=[]
if actual['failures'] or actual['checks']<=0:failures.append('GPU logical checks failed')
if [c['name'] for c in fixtures]!=[c['name'] for c in actual['cases']]:raise ValueError('Cohort mismatch')
for case,result in zip(fixtures,actual['cases']):
    initial=unpack(result['initial']['particles']);initial_total=particle_totals(initial,case['dx'],case['origin'])
    momentum_bound=2e-5*case['linear_scale']+1e-7
    angular_bound=3e-5*case['angular_scale']+1e-8
    energy_bound=2e-5*case['initial_totals']['kinetic_energy']+1e-9
    maxima=dict(position_error_m=0.,velocity_error_m_s=0.,affine_error_s_inv=0.,grid_mass_relative_error=0.,
                linear_drift=0.,angular_drift=0.,angular_error_vs_binary64=0.,energy_excess_vs_binary64_J=0.,
                grid_linear_transfer_error=0.,grid_angular_transfer_error=0.,translation_error_m=0.)
    if len(case['snapshots'])!=len(result['snapshots']):raise ValueError('Checkpoint count mismatch')
    for expected,state in zip(case['snapshots'],result['snapshots']):
        if state['status'][0]!=expected['ticks'] or bool(state['status'][1])!=expected['halted']:failures.append(case['name']+': wrong admitted ticks')
        particles=unpack(state['particles']);reference=unpack([v for row in expected['particles'] for v in row])
        if len(particles)!=len(reference):raise ValueError('Particle count mismatch')
        total=particle_totals(particles,case['dx'],case['origin'])
        grid=grid_totals(grid_unpack(state['grid'],case['shape']),case['dx'],case['origin'])
        maxima['position_error_m']=max(maxima['position_error_m'],max(norm(sub(p.position,q.position)) for p,q in zip(particles,reference)))
        maxima['velocity_error_m_s']=max(maxima['velocity_error_m_s'],max(norm(sub(p.velocity,q.velocity)) for p,q in zip(particles,reference)))
        maxima['affine_error_s_inv']=max(maxima['affine_error_s_inv'],max(abs(p.affine[a][b]-q.affine[a][b]) for p,q in zip(particles,reference) for a in range(3) for b in range(3)))
        maxima['grid_mass_relative_error']=max(maxima['grid_mass_relative_error'],abs(grid['mass']-total['mass'])/total['mass'])
        maxima['linear_drift']=max(maxima['linear_drift'],norm(sub(total['linear_momentum'],initial_total['linear_momentum'])))
        maxima['angular_drift']=max(maxima['angular_drift'],norm(sub(total['angular_momentum'],initial_total['angular_momentum'])))
        maxima['angular_error_vs_binary64']=max(maxima['angular_error_vs_binary64'],norm(sub(total['angular_momentum'],expected['totals']['angular_momentum'])))
        maxima['energy_excess_vs_binary64_J']=max(maxima['energy_excess_vs_binary64_J'],total['kinetic_energy']-expected['totals']['kinetic_energy'])
        maxima['grid_linear_transfer_error']=max(maxima['grid_linear_transfer_error'],norm(sub(grid['linear_momentum'],total['linear_momentum'])))
        maxima['grid_angular_transfer_error']=max(maxima['grid_angular_transfer_error'],norm(sub(grid['angular_momentum'],total['angular_momentum'])))
        if case['name'].startswith('translation_'):
            for p,q in zip(particles,initial):
                analytic=tuple(x+expected['ticks']*case['dt']*v for x,v in zip(q.position,q.velocity))
                maxima['translation_error_m']=max(maxima['translation_error_m'],norm(sub(p.position,analytic)))
    limits={'position_error_m':5e-5,'velocity_error_m_s':3e-4,'affine_error_s_inv':5e-3,'grid_mass_relative_error':2e-6,
            'linear_drift':momentum_bound,'angular_error_vs_binary64':angular_bound,'energy_excess_vs_binary64_J':energy_bound,
            'grid_linear_transfer_error':momentum_bound,'grid_angular_transfer_error':angular_bound,'translation_error_m':5e-5}
    if case['method']=='apic':limits['angular_drift']=angular_bound
    for name,limit in limits.items():
        if maxima[name]>limit:failures.append('%s %s %.12g exceeds %.12g'%(case['name'],name,maxima[name],limit))
    initial_L=norm(initial_total['angular_momentum'])
    metric=dict(name=case['name'],**maxima,linear_bound=momentum_bound,angular_bound=angular_bound,
                initial_energy_J=initial_total['kinetic_energy'],final_energy_J=total['kinetic_energy'],
                represented_energy_retained=total['kinetic_energy']/initial_total['kinetic_energy'],
                binary64_energy_retained=expected['totals']['kinetic_energy']/case['initial_totals']['kinetic_energy'],
                angular_retained=norm(total['angular_momentum'])/initial_L if initial_L>1e-10 else None)
    metrics.append(metric);print('METRIC '+json.dumps(metric,sort_keys=True))
(EVIDENCE/'metrics.json').write_text(json.dumps(dict(metrics=metrics,failures=failures),indent=2)+'\n')
for failure in failures:print('FAIL '+failure)
print('MOMENTUM_MOTION_NUMERICS failures=%d'%len(failures))
raise SystemExit(bool(failures))
