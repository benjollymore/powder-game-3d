import json,math,unittest
from pathlib import Path
from tools.feasibility.momentum_reference import Particle,particle_totals,add,sub,dot
from tools.feasibility.momentum_gpu.reference import step
from tools.feasibility.mechanics_gpu.reference import mechanics_step

CASES=json.loads((Path(__file__).parent/'mechanics_gpu/cases.json').read_text())['cases']
def unpack(rows):return [Particle(tuple(p[:3]),tuple(p[4:7]),p[3],tuple(tuple(p[j:j+3]) for j in [8,12,16])) for p in rows]
def norm(v):return math.sqrt(dot(v,v))
def case(name):return next(c for c in CASES if c['name']==name)

class MechanicsReferenceTests(unittest.TestCase):
    def test_gravity_discrete_trajectory_and_energy_defect(self):
        c=case('gravity_apic');ps=unpack(c['initial_particles']);initial=particle_totals(ps,c['dx'],c['origin']);start=ps
        for _ in range(10):ps,_,_,ok,_=mechanics_step(ps,c['dx'],c['shape'],c['dt'],c['method'],c['gravity'],None,c['origin']);self.assertTrue(ok)
        for p,q in zip(ps,start):
            expected=tuple(x+10*c['dt']*v+c['dt']**2*g*55 for x,v,g in zip(q.position,q.velocity,c['gravity']))
            self.assertLess(norm(sub(p.position,expected)),1e-12)
        final=particle_totals(ps,c['dx'],c['origin'])
        dp=tuple(initial['mass']*g*10*c['dt'] for g in c['gravity'])
        self.assertLess(norm(sub(sub(final['linear_momentum'],initial['linear_momentum']),dp)),1e-12)
        du=-math.fsum(p.mass*dot(c['gravity'],sub(p.position,q.position)) for p,q in zip(ps,start))
        expected=-.5*initial['mass']*dot(c['gravity'],c['gravity'])*c['dt']**2*10
        self.assertAlmostEqual(final['kinetic_energy']-initial['kinetic_energy']+du,expected,places=12)
    def test_apic_contact_impulse_torque_and_node_constraint(self):
        c=case('plane_apic');ps=unpack(c['initial_particles']);before=particle_totals(ps,c['dx'],c['origin'])
        new,ledger,nodes,ok,_=mechanics_step(ps,c['dx'],c['shape'],c['dt'],c['method'],c['gravity'],c['plane'],c['origin'])
        self.assertTrue(ok);after=particle_totals(new,c['dx'],c['origin'])
        self.assertGreater(norm(ledger[2][:3]),1e-4);self.assertGreater(norm(ledger[5][:3]),1e-5)
        self.assertLess(norm(sub(sub(after['linear_momentum'],before['linear_momentum']),ledger[2][:3])),1e-12)
        self.assertLess(norm(sub(sub(after['angular_momentum'],before['angular_momentum']),ledger[5][:3])),1e-12)
        self.assertLess(ledger[2][3],0)
        for n in nodes:
            if n['selected']:
                self.assertEqual(n['after'][1],0);self.assertEqual(n['after'][0],n['gravity'][0]);self.assertEqual(n['after'][2],n['gravity'][2])
                self.assertAlmostEqual(n['ww'],-.5*n['mass']*n['gravity'][1]**2,places=14)
            else:self.assertEqual(n['after'],n['gravity'])
    def test_pic_contact_angular_loss_negative_control(self):
        # PIC cannot hold the lower cluster's sub-grid rotation, so its particle
        # angular balance against the wall torque fails where APIC's holds.
        # The no-plane control shows how much of that is plain transfer loss.
        c=case('plane_pic');ps=unpack(c['initial_particles']);before=particle_totals(ps,c['dx'],c['origin'])
        self.assertGreater(norm(before['orbital_angular_momentum']),1e-6);self.assertEqual(before['affine_angular_momentum'],(0.,0.,0.))
        residuals={}
        for label,plane in [('wall',c['plane']),('free',None)]:
            new,ledger,_,ok,_=mechanics_step(ps,c['dx'],c['shape'],c['dt'],c['method'],c['gravity'],plane,c['origin'])
            self.assertTrue(ok);after=particle_totals(new,c['dx'],c['origin'])
            residuals[label]=norm(sub(sub(after['angular_momentum'],before['angular_momentum']),ledger[5][:3]))
            if plane is None:self.assertEqual(ledger[5][:3],[0.,0.,0.])
            else:self.assertGreater(norm(ledger[5][:3]),1e-5)
        self.assertGreater(residuals['wall'],1e-6);self.assertGreater(residuals['free'],1e-6)
        print('METRIC pic_wall_angular_residual',residuals['wall'],'pic_free_angular_residual',residuals['free'])
    def test_irrotational_plane_contact_is_not_a_pic_discriminator(self):
        # Recorded limit: a flat frictionless plane on a translating cluster only
        # varies v_y along y, and the separable quadratic stencil transfers that
        # with zero angular residual for PIC. Rotation is what the fixture needs.
        c=case('plane_pic');origin=c['origin']
        ps=[Particle(p.position,(.1,-.25,0.),p.mass) for p in unpack(c['initial_particles'])]
        before=particle_totals(ps,c['dx'],origin)
        new,ledger,_,ok,_=mechanics_step(ps,c['dx'],c['shape'],c['dt'],'pic',c['gravity'],c['plane'],origin)
        self.assertTrue(ok);self.assertGreater(norm(ledger[5][:3]),1e-5)
        after=particle_totals(new,c['dx'],origin)
        self.assertLess(norm(sub(sub(after['angular_momentum'],before['angular_momentum']),ledger[5][:3])),1e-15)
    def test_large_step_rejection_has_no_committed_ledger(self):
        c=case('rejected_plane_apic');ps=unpack(c['initial_particles'])
        new,attempt,_,ok,reason=mechanics_step(ps,c['dx'],c['shape'],c['dt'],c['method'],c['gravity'],c['plane'],c['origin'])
        self.assertFalse(ok);self.assertEqual(reason,4);self.assertEqual(new,ps);self.assertGreater(norm(attempt[2][:3]),0)
        self.assertTrue(all(x==0 for row in c['snapshots'][-1]['ledger'] for x in row))
    def test_initial_halfspace_rejected(self):
        with self.assertRaises(ValueError):mechanics_step([Particle((.3,.15,.3),(0.,0.,0.),.01)],.1,(10,10,10),.001,'apic',(0.,0.,0.),.2,(0.,0.,0.))
    def test_forcefree_method_unchanged(self):
        ps=[Particle((.3,.3,.3),(.1,-.2,.05),.01),Particle((.35,.32,.33),(-.1,.1,0.),.02)]
        for method in ['pic','apic']:
            a,_,accepted=step(ps,.1,(10,10,10),.001,method)
            b,ledger,_,ok,_=mechanics_step(ps,.1,(10,10,10),.001,method,(0.,0.,0.),None,(0.,0.,0.))
            self.assertEqual(a,b);self.assertEqual(accepted,ok)
            self.assertTrue(all(x==0 for row in ledger[:4] for x in row))

if __name__=='__main__':unittest.main()
