"""Apply the predeclared FP32 mechanics gates; do not rebaseline failures.

Compares docs/milestone/evidence-mechanics-gpu/results.json (synchronized GPU
readbacks) against the binary64 reference trajectories and ledgers in
tests/feasibility/mechanics_gpu/cases.json, using the bounds declared in
docs/milestone/mechanics-experiment-plan.md before any GPU run.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import sys
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))
from tools.feasibility.momentum_reference import Particle,Node,particle_totals,grid_totals,add,sub,scale,dot
parser=argparse.ArgumentParser()
parser.add_argument('--evidence-dir',default='docs/milestone/evidence-mechanics-gpu')
parser.add_argument('--results',default='results.json')
parser.add_argument('--metrics',default='metrics.json')
args=parser.parse_args()
EVIDENCE=ROOT/args.evidence_dir
POSITION_LIMIT,VELOCITY_LIMIT,AFFINE_LIMIT,GRID_MASS_LIMIT,WALL_WORK_LIMIT=5e-5,3e-4,5e-3,2e-6,1e-9

def f32(x):return struct.unpack('f',struct.pack('f',x))[0]
def norm(v):return math.sqrt(math.fsum(x*x for x in v))
def unpack(flat):
    if len(flat)%20 or not all(math.isfinite(x) for x in flat):raise ValueError('Invalid particle record')
    return [Particle(tuple(flat[i:i+3]),tuple(flat[i+4:i+7]),flat[i+3],tuple(tuple(flat[i+j:i+j+3]) for j in [8,12,16])) for i in range(0,len(flat),20)]
def grid_unpack(flat,shape):
    if len(flat)!=math.prod(shape)*4 or not all(math.isfinite(x) for x in flat):raise ValueError('Invalid grid record')
    nx,ny,nz=shape
    return {(i%nx,(i//nx)%ny,i//(nx*ny)):Node(flat[i*4+3],tuple(flat[i*4:i*4+3])) for i in range(nx*ny*nz) if flat[i*4+3]>0}
def centroid(particles):
    m=math.fsum(p.mass for p in particles)
    return tuple(math.fsum(p.mass*p.position[a] for p in particles)/m for a in range(3)),tuple(math.fsum(p.mass*p.velocity[a] for p in particles)/m for a in range(3)),m

fixtures=json.loads((ROOT/'tests/feasibility/mechanics_gpu/cases.json').read_text())['cases']
actual=json.loads((EVIDENCE/args.results).read_text())
failures=[];metrics=[]
if actual['failures'] or actual['checks']<=0:failures.append('GPU logical checks failed')
if [c['name'] for c in fixtures]!=[c['name'] for c in actual['cases']]:raise ValueError('Cohort mismatch')
for case,result in zip(fixtures,actual['cases']):
    dx,shape,dt,origin=case['dx'],tuple(case['shape']),case['dt'],tuple(case['origin'])
    plane,gravity=case['plane'],tuple(case['gravity'])
    forced=any(g!=0 for g in gravity)
    initial=unpack(result['initial']['particles']);initial_total=particle_totals(initial,dx,origin)
    x0,v0,total_mass=centroid(initial)
    if len(case['snapshots'])!=len(result['snapshots']):raise ValueError('Checkpoint count mismatch')
    maxima=dict(position_error_m=0.,velocity_error_m_s=0.,affine_error_s_inv=0.,grid_mass_relative_error=0.,
                grid_linear_transfer_error=0.,grid_angular_transfer_error=0.,
                linear_balance_residual=0.,angular_balance_residual=0.,angular_residual_vs_binary64=0.,
                gravity_applied_vs_requested=0.,gravity_applied_vs_analytic=0.,wall_applied_vs_requested=0.,
                gravity_torque_applied_vs_requested=0.,wall_torque_applied_vs_requested=0.,
                ledger_impulse_vs_binary64=0.,ledger_torque_vs_binary64=0.,ledger_work_vs_binary64=0.,
                energy_identity_residual_J=0.,energy_vs_binary64_J=0.,wall_work_J=-math.inf,com_trajectory_error_m=0.,
                node_impulse_error=0.,node_work_error_J=0.,node_gravity_velocity_error_m_s=0.,node_exact_violations=0,rejected_candidate_min_y_minus_plane=0.)
    bounds={};selected_nodes=0;wall_impulse=0.;rejected_wall_impulse=0.;last=None
    for expected,state in zip(case['snapshots'],result['snapshots']):
        ticks=state['status'][0]
        if ticks!=expected['ticks'] or bool(state['status'][1])!=expected['halted']:failures.append(case['name']+': wrong admitted ticks')
        particles=unpack(state['particles']);reference=unpack([v for row in expected['particles'] for v in row])
        if len(particles)!=len(reference):raise ValueError('Particle count mismatch')
        total=particle_totals(particles,dx,origin)
        grid=grid_totals(grid_unpack(state['grid'],shape),dx,origin)
        ledger=[state['ledger'][k*4:(k+1)*4] for k in range(10)];ref=expected['ledger']
        impulse_sum,torque_sum,work_sum=ledger[4][3],ledger[5][3],ledger[8][0]
        linear_bound=3e-5*(case['linear_scale']+impulse_sum)+1e-7
        angular_bound=5e-5*(case['angular_scale']+torque_sum)+1e-8
        energy_bound=5e-5*(initial_total['kinetic_energy']+work_sum)+1e-9
        bounds=dict(linear_bound=linear_bound,angular_bound=angular_bound,energy_bound=energy_bound)
        up=lambda key,value:maxima.__setitem__(key,max(maxima[key],value))
        up('position_error_m',max(norm(sub(p.position,q.position)) for p,q in zip(particles,reference)))
        up('velocity_error_m_s',max(norm(sub(p.velocity,q.velocity)) for p,q in zip(particles,reference)))
        up('affine_error_s_inv',max(abs(p.affine[a][b]-q.affine[a][b]) for p,q in zip(particles,reference) for a in range(3) for b in range(3)))
        up('grid_mass_relative_error',abs(grid['mass']-total['mass'])/total['mass'])
        up('grid_linear_transfer_error',norm(sub(grid['linear_momentum'],total['linear_momentum'])))
        up('grid_angular_transfer_error',norm(sub(grid['angular_momentum'],total['angular_momentum'])))
        applied_impulse=add(ledger[0][:3],ledger[2][:3]);applied_torque=add(ledger[4][:3],ledger[5][:3])
        up('linear_balance_residual',norm(sub(sub(total['linear_momentum'],initial_total['linear_momentum']),applied_impulse)))
        angular_residual=norm(sub(sub(total['angular_momentum'],initial_total['angular_momentum']),applied_torque))
        up('angular_balance_residual',angular_residual)
        ref_residual=norm(sub(sub(expected['totals']['angular_momentum'],case['initial_totals']['angular_momentum']),add(ref[4][:3],ref[5][:3])))
        up('angular_residual_vs_binary64',abs(angular_residual-ref_residual))
        up('gravity_applied_vs_requested',norm(sub(ledger[0][:3],ledger[1][:3])))
        up('gravity_applied_vs_analytic',norm(sub(ledger[0][:3],scale(gravity,total_mass*dt*ticks))))
        up('wall_applied_vs_requested',norm(sub(ledger[2][:3],ledger[3][:3])))
        up('gravity_torque_applied_vs_requested',norm(sub(ledger[4][:3],ledger[6][:3])))
        up('wall_torque_applied_vs_requested',norm(sub(ledger[5][:3],ledger[7][:3])))
        for row in range(4):up('ledger_impulse_vs_binary64',norm(sub(ledger[row][:3],ref[row][:3])))
        for row in range(4,8):up('ledger_torque_vs_binary64',norm(sub(ledger[row][:3],ref[row][:3])))
        for row in [0,2,6,7]:up('ledger_work_vs_binary64',abs(ledger[row][3]-ref[row][3]))
        transfer_loss_in,transfer_loss_out=ledger[6][3],ledger[7][3]
        external_work=ledger[0][3]+ledger[2][3]
        up('energy_identity_residual_J',abs(total['kinetic_energy']-initial_total['kinetic_energy']-(transfer_loss_in+transfer_loss_out+external_work)))
        up('energy_vs_binary64_J',abs(total['kinetic_energy']-expected['totals']['kinetic_energy']))
        up('wall_work_J',ledger[2][3])
        if forced:
            com,_,_=centroid(particles)
            analytic=tuple(x+ticks*dt*v+dt*dt*g*ticks*(ticks+1)/2 for x,v,g in zip(x0,v0,gravity))
            up('com_trajectory_error_m',norm(sub(com,analytic)))
        if expected['halted'] and ticks==0:
            if any(v!=0. for v in state['ledger']):failures.append(case['name']+': rejected steps committed a ledger')
            if state['particles']!=result['initial']['particles']:failures.append(case['name']+': rejected steps moved particles')
            if plane is not None:
                maxima['rejected_candidate_min_y_minus_plane']=state['attempt_meta'][2]-plane
                if not maxima['rejected_candidate_min_y_minus_plane']<0:failures.append(case['name']+': rejected candidate never crossed the plane')
        nx,ny=shape[0],shape[1]
        for node in state['nodes']:
            v=node['values'];iy=(node['index']//nx)%ny;y=f32(f32(iy)*f32(dx));m=v[3]
            before,after_g,after_w=v[0:3],v[4:7],v[8:11]
            jg,wg,jg_req,wg_req,jw,ww,jw_req,ww_req=v[12:15],v[15],v[16:19],v[19],v[20:23],v[23],v[24:27],v[27]
            selected=plane is not None and y<=f32(plane) and after_g[1]<0
            exact=True
            if selected:
                selected_nodes+=1
                exact&=after_w[1]==0. and after_w[0]==after_g[0] and after_w[2]==after_g[2]
                up('node_impulse_error',norm(sub(jw,(0.,-m*after_g[1],0.))))
                up('node_work_error_J',abs(ww-(-.5*m*after_g[1]**2)))
                exact&=norm(jw_req)>0
            else:
                exact&=tuple(after_w)==tuple(after_g) and all(x==0. for x in jw) and ww==0. and all(x==0. for x in jw_req)
            up('node_impulse_error',norm(sub(jg,scale(gravity,m*dt))))
            up('node_impulse_error',norm(sub(jg,jg_req)))
            up('node_work_error_J',abs(wg-wg_req))
            # Gravity is an FP32 increment; only the wall stage is byte-exact by contract.
            if forced:up('node_gravity_velocity_error_m_s',norm(sub(after_g,add(before,scale(gravity,dt)))))
            else:exact&=tuple(after_g)==tuple(before)
            if not exact:maxima['node_exact_violations']+=1
            if expected['halted']:rejected_wall_impulse=max(rejected_wall_impulse,norm(jw))
        wall_impulse=norm(ledger[2][:3]);last=(expected,state,total)
    limits={'position_error_m':POSITION_LIMIT,'velocity_error_m_s':VELOCITY_LIMIT,'affine_error_s_inv':AFFINE_LIMIT,
            'grid_mass_relative_error':GRID_MASS_LIMIT,'grid_linear_transfer_error':bounds['linear_bound'],
            'grid_angular_transfer_error':bounds['angular_bound'],'linear_balance_residual':bounds['linear_bound'],
            'angular_residual_vs_binary64':bounds['angular_bound'],'gravity_applied_vs_requested':bounds['linear_bound'],
            'gravity_applied_vs_analytic':bounds['linear_bound'],'wall_applied_vs_requested':bounds['linear_bound'],
            'gravity_torque_applied_vs_requested':bounds['angular_bound'],'wall_torque_applied_vs_requested':bounds['angular_bound'],
            'ledger_impulse_vs_binary64':bounds['linear_bound'],'ledger_torque_vs_binary64':bounds['angular_bound'],
            'ledger_work_vs_binary64':bounds['energy_bound'],'energy_identity_residual_J':bounds['energy_bound'],
            'energy_vs_binary64_J':bounds['energy_bound'],'wall_work_J':WALL_WORK_LIMIT,'com_trajectory_error_m':POSITION_LIMIT,
            'node_impulse_error':bounds['linear_bound'],'node_work_error_J':bounds['energy_bound'],'node_exact_violations':0,
            'node_gravity_velocity_error_m_s':VELOCITY_LIMIT}
    if case['method']=='apic':limits['angular_balance_residual']=bounds['angular_bound']
    for name,limit in limits.items():
        if maxima[name]>limit:failures.append('%s %s %.12g exceeds %.12g'%(case['name'],name,maxima[name],limit))
    if plane is not None and not case['snapshots'][-1]['halted'] and wall_impulse<=0:failures.append(case['name']+': plane fixture applied no wall impulse')
    if plane is not None and case['snapshots'][-1]['halted'] and rejected_wall_impulse<=0:failures.append(case['name']+': rejected attempt recorded no wall impulse')
    if plane is not None and selected_nodes==0:failures.append(case['name']+': no node was ever constrained')
    expected,state,total=last
    initial_L=norm(initial_total['angular_momentum'])
    ledger=[state['ledger'][k*4:(k+1)*4] for k in range(10)]
    metric=dict(name=case['name'],method=case['method'],ticks=state['status'][0],**maxima,**bounds,selected_node_records=selected_nodes,
                applied_gravity_impulse=ledger[0][:3],applied_wall_impulse=ledger[2][:3],applied_gravity_torque=ledger[4][:3],applied_wall_torque=ledger[5][:3],
                gravity_work_J=ledger[0][3],transfer_loss_in_J=ledger[6][3],transfer_loss_out_J=ledger[7][3],
                initial_energy_J=initial_total['kinetic_energy'],final_energy_J=total['kinetic_energy'],
                binary64_final_energy_J=expected['totals']['kinetic_energy'],
                angular_retained=norm(total['angular_momentum'])/initial_L if initial_L>1e-10 else None,
                binary64_angular_residual=norm(sub(sub(expected['totals']['angular_momentum'],case['initial_totals']['angular_momentum']),add(expected['ledger'][4][:3],expected['ledger'][5][:3]))))
    metrics.append(metric);print('METRIC '+json.dumps(metric,sort_keys=True))
(EVIDENCE/args.metrics).write_text(json.dumps(dict(metrics=metrics,failures=failures),indent=2)+'\n')
for failure in failures:print('FAIL '+failure)
print('MECHANICS_NUMERICS failures=%d'%len(failures))
raise SystemExit(bool(failures))
