import unittest
from tools.feasibility.momentum_reference import Particle,particle_totals,sub
from tools.feasibility.momentum_gpu.reference import step

class MomentumMotionTests(unittest.TestCase):
    def test_translation_advects(self):
        p=[Particle((.3,.3,.3),(.1,.2,.3),.01)]
        for method in ['pic','apic']:
            q,_,ok=step(p,.1,(10,10,10),.02,method)
            self.assertTrue(ok)
            for a,b in zip(q[0].position,(.302,.304,.306)):self.assertAlmostEqual(a,b,places=13)
    def test_boundary_rejects_every_particle(self):
        p=[Particle((.843,.3,.3),(.1,0.,0.),.01),Particle((.3,.3,.3),(.02,0.,0.),.02)]
        q,_,ok=step(p,.1,(10,10,10),.1,'apic')
        self.assertFalse(ok);self.assertEqual(p,q)
    def test_invalid_old_support_rejected(self):
        with self.assertRaises(ValueError):step([Particle((.01,.3,.3),(0.,0.,0.),.01)],.1,(10,10,10),.01,'apic')
    def test_invalid_dt(self):
        p=[Particle((.3,.3,.3),(0.,0.,0.),.01)]
        for dt in [0,-1,float('inf'),float('nan')]:
            with self.assertRaises(ValueError):step(p,.1,(10,10,10),dt,'apic')

if __name__=='__main__':unittest.main()
