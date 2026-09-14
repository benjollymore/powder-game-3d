import math
import random
import unittest

from tools.feasibility.enthalpy_remap import (Run, Session, column_target, remap, replace_cell)
from tools.feasibility.thermal_reference import Material

# Explicit illustrative scale; production density is a buoyancy ordering value,
# not a calibrated kg/m^3 material table. 200 units = one 1cm cube at 1000kg/m^3.
LIQUID = Material("synthetic transported liquid", 1000, 10, 1000, 1000, 100)
UNIT_MASS = LIQUID.density * .01**3 / 200


def make(amounts, temperatures=None):
    return Run.at_temperatures(LIQUID, UNIT_MASS, amounts, temperatures or [350]*len(amounts))


class RemapTests(unittest.TestCase):
    def test_snapshot_cannot_alias_mutable_energy(self):
        # A frozen dataclass alone does not freeze a caller-owned energy list.
        # Reject that alias before it can invalidate a saved runtime ledger.
        with self.assertRaises(ValueError):
            Session(Run(LIQUID, UNIT_MASS, (100,), [1.0])).snapshot()

    def assert_ledger(self, old, new, ledger):
        mass_error, energy_error = ledger.residuals(UNIT_MASS)
        self.assertLessEqual(abs(mass_error), 1e-15)
        self.assertLessEqual(abs(energy_error), 1e-12*max(1, math.fsum(abs(e) for e in old.energy)))
        self.assertEqual(sum(new.amounts), ledger.new_units)
        for a, e in zip(new.amounts, new.energy):
            if not a:
                self.assertEqual(e, 0.)

    def test_column_known_profiles(self):
        for old, expected in [([100,100,100], [200,100,0]), ([200]*3,[202,200,198]),
                              ([255,1,144],[200,200,0]), ([1]*256,[200,56]+[0]*254),
                              ([255]*256,[255]*256)]:
            self.assertEqual(column_target(old), tuple(expected))

    def test_all_two_cell_amounts_conserve_integer_mass(self):
        for a in range(1,256):
            for b in range(1,256):
                target = column_target([a,b])
                self.assertEqual(sum(target), a+b)
                self.assertTrue(all(0 <= q <= 255 for q in target))

    def test_uniform_temperature_partial_and_compressed(self):
        for temperature in [250., 273.15, 350., 600.]:
            old = make([255,1,144,200,3], [temperature]*5)
            for policy in ["monotone", "retain"]:
                new, _, ledger = remap(old, column_target(old.amounts), policy)
                self.assert_ledger(old,new,ledger)
                for value in new.temperatures():
                    if value is not None:
                        self.assertAlmostEqual(value, temperature, places=10)

    def test_real_column_hot_cold_mixing(self):
        old = make([100]*3,[300,400,500])
        new, transfers, ledger = remap(old,column_target(old.amounts))
        self.assertEqual(new.amounts,(200,100,0))
        self.assertEqual(new.temperatures(),(350.,500.,None))
        self.assertEqual([(t.donor,t.receiver,t.units) for t in transfers],[(0,0,100),(1,0,100),(2,1,100)])
        self.assert_ledger(old,new,ledger)

    def test_hydro_amount_endpoints_do_not_determine_heat_path(self):
        old=make([100]*3,[300,400,500]); target=column_target(old.amounts)
        monotone,_,a=remap(old,target,"monotone")
        retain,_,b=remap(old,target,"retain")
        self.assertEqual(monotone.amounts,retain.amounts)
        self.assertEqual(retain.temperatures(),(400.,400.,None))
        self.assertNotEqual(monotone.energy,retain.energy)
        self.assert_ledger(old,monotone,a); self.assert_ledger(old,retain,b)
        print("METRIC path_ambiguity monotone_K=%s retain_K=%s total_J=%.12g" %
              (monotone.temperatures(),retain.temperatures(),old.joules()))

    def test_preserving_cell_temperature_naively_loses_energy(self):
        old=make([100]*3,[300,400,500]); target=column_target(old.amounts)
        naive=make(target,[300,400,500])
        self.assertAlmostEqual(naive.joules()-old.joules(),-100.,places=10)
        print("METRIC naive_fixed_temperature energy_error_J=%.12g" % (naive.joules()-old.joules()))

    def test_compressed_amount_means_extra_mass_not_clamped_fill(self):
        old=make([255,1],[500,250]); new,_,ledger=remap(old,column_target(old.amounts))
        self.assertAlmostEqual(old.mass(),256*UNIT_MASS)
        self.assertEqual(new.amounts,(200,56))
        self.assert_ledger(old,new,ledger)

    def test_donor_budgets_are_synchronous_not_reused_incoming_heat(self):
        old=make([100]*3,[300,400,500]); new,transfers,ledger=remap(old,[200,100,0])
        for donor in range(3):
            parts=[t for t in transfers if t.donor==donor]
            self.assertEqual(sum(t.units for t in parts),old.amounts[donor])
            self.assertAlmostEqual(math.fsum(t.joules for t in parts),old.energy[donor],places=12)
        for receiver in range(3):
            self.assertEqual(sum(t.units for t in transfers if t.receiver==receiver),new.amounts[receiver])
        self.assert_ledger(old,new,ledger)

    def test_thousand_random_remaps_keep_mass_and_energy(self):
        rng=random.Random(3107)
        initial=make([rng.randrange(1,256) for _ in range(32)],[rng.uniform(240,600) for _ in range(32)])
        run=initial; worst=0.
        for _ in range(1000):
            target=list(run.amounts); rng.shuffle(target)
            new,_,ledger=remap(run,target)
            self.assert_ledger(run,new,ledger)
            worst=max(worst,abs(new.joules()-initial.joules()))
            run=new
        self.assertEqual(sum(run.amounts),sum(initial.amounts))
        relative=worst/math.fsum(abs(e) for e in initial.energy)
        self.assertLessEqual(relative,1e-12)
        print("METRIC remap1000 mass_units=%d relative_energy_drift=%.12g max_drift_J=%.12g" %
              (sum(run.amounts),relative,worst))

    def test_frame_batching_keeps_ordered_events_exact(self):
        rng=random.Random(921)
        initial=make([20,180,255,145],[250,350,450,550]); targets=[]
        for _ in range(83):
            target=list(initial.amounts);rng.shuffle(target);targets.append(target)
        snapshots=[]
        for schedule in [[1],[3],[7,2,5,1,9]]:
            session=Session(initial);done=part=0
            while done<len(targets):
                count=min(schedule[part%len(schedule)],len(targets)-done)
                for target in targets[done:done+count]: session.step(target)
                done+=count;part+=1
            snapshots.append(session.snapshot())
        self.assertEqual(snapshots[0],snapshots[1]);self.assertEqual(snapshots[0],snapshots[2])

    def test_coalescing_remap_events_changes_heat_even_if_amounts_return(self):
        old=make([100]*3,[300,400,500])
        middle,_,_=remap(old,[200,100,0]); roundtrip,_,_=remap(middle,old.amounts)
        skipped,_,_=remap(old,old.amounts)
        self.assertEqual(roundtrip.amounts,skipped.amounts)
        self.assertNotEqual(roundtrip.energy,skipped.energy)
        self.assertEqual(roundtrip.temperatures(),(350.,350.,500.))
        print("METRIC coalescing_limit ordered_K=%s skipped_K=%s" % (roundtrip.temperatures(),skipped.temperatures()))

    def test_replace_and_erase_have_explicit_external_ledgers(self):
        old=make([255,100],[450,300])
        placed,a=replace_cell(old,1,200,500); self.assert_ledger(old,placed,a)
        erased,b=replace_cell(placed,0,0,300); self.assert_ledger(placed,erased,b)
        self.assertEqual(erased.energy[0],0.)
        self.assertAlmostEqual(a.mass_out,100*UNIT_MASS)
        self.assertAlmostEqual(b.energy_out,old.energy[0])

    def test_runtime_restore_and_authored_reset_have_distinct_ledgers(self):
        initial=make([100]*3,[300,400,500]);session=Session(initial)
        session.edit(0,200,600);saved=session.snapshot()
        session.step([200,200,0]);session.edit(1,0,300)
        session.restore(saved);self.assertEqual(session.snapshot(),saved)
        session.reset(initial)
        self.assertEqual(session.snapshot().run,initial)
        self.assertEqual((session.ticks,session.mass_net,session.energy_net),(0,0,0))

    def test_rejects_unsupported_or_invalid_contracts_atomically(self):
        old=make([100,100]);session=Session(old);before=session.snapshot()
        for target in [[200], [100,99], [256,-56], [100.,100], [True,199]]:
            with self.assertRaises(ValueError): session.step(target)
            self.assertEqual(session.snapshot(),before)
        with self.assertRaises(ValueError):column_target([100,0,100])
        with self.assertRaises(ValueError):remap(old,[100,100],"unspecified")
        with self.assertRaises(ValueError):Run(LIQUID,UNIT_MASS,(0,),(1.,))
        pcm=Material("partially molten",1000,10,1000,1000,300,100000)
        with self.assertRaises(ValueError):Run(pcm,UNIT_MASS,(100,),(100*UNIT_MASS*pcm.specific_enthalpy(300,.5),))


if __name__ == "__main__": unittest.main()
