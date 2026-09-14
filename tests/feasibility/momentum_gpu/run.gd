extends SceneTree
signal ready_result(result: Dictionary)
var _gpu: RefCounted
var _checks:=0
var _failures:=0
var _results:={"cases":[],"checks":0,"failures":0}

func _initialize() -> void:
	root.get_node("TimeController").paused=true
	create_timer(120).timeout.connect(func():push_error("Momentum motion test timed out");quit(1))
	call_deferred("_run")

func _run() -> void:
	var cases: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://tests/feasibility/momentum_gpu/cases.json"))
	for case in cases.cases:
		_gpu=load("res://tools/feasibility/momentum_gpu/gpu.gd").new()
		RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
		var initial: Dictionary=await ready_result
		_check(initial.status[0]==0 and initial.status[1]==0,"%s initial complete support admitted"%case.name)
		var result:={"name":case.name,"initial":initial,"snapshots":[]}
		var attempted:=0
		for expected in case.snapshots:
			RenderingServer.call_on_render_thread(_rt_advance.bind(int(expected.attempted)-attempted,case.dt))
			var current: Dictionary=await ready_result
			_check(current.status[0]==expected.ticks and bool(current.status[1])==expected.halted,"%s attempted%d actual GPU acceptance status"%[case.name,expected.attempted])
			_check(current.mass_hash==initial.mass_hash,"%s attempted%d particle mass bytes unchanged"%[case.name,expected.attempted])
			if expected.halted:
				_check(current.particle_hash==result.snapshots[-1].particle_hash,"%s rejects whole step without moving any particle"%case.name)
				_check(current.grid_hash==result.snapshots[-1].grid_hash,"%s rejected advection retains the grid of last authoritative particles"%case.name)
			result.snapshots.append(current);attempted=int(expected.attempted)
		var final: Dictionary=result.snapshots[-1]
		if case.name in ["nonaffine_apic","boundary_atomic_apic"]:
			for schedule in [[1],[3],[7,2,5,1,9]]:
				RenderingServer.call_on_render_thread(_rt_reset.bind(case.initial_particles))
				await ready_result
				var total:=0
				var part:=0
				while total<case.steps:
					var count:=mini(schedule[part%schedule.size()],int(case.steps)-total)
					RenderingServer.call_on_render_thread(_gpu.advance.bind(count,case.dt))
					total+=count;part+=1
				RenderingServer.call_on_render_thread(_rt_snapshot)
				var grouped: Dictionary=await ready_result
				_check(grouped.particle_hash==final.particle_hash and grouped.status==final.status,"%s batches%s preserve particle and status bytes"%[case.name,schedule])
			for dt in [-1.0,0.0,INF,NAN,1e-100,1e40]:
				RenderingServer.call_on_render_thread(_rt_advance.bind(1,dt))
				var invalid: Dictionary=await ready_result
				_check(not invalid.accepted_submission and invalid.particle_hash==final.particle_hash and invalid.status==final.status,"%s invalid timestep does not mutate state"%case.name)
		_results.cases.append(result)
		if case.name=="translation_apic":
			var invalid_positions: Array=case.initial_particles.duplicate(true)
			invalid_positions[0][0]=0.01
			RenderingServer.call_on_render_thread(_rt_reset.bind(invalid_positions))
			var rejected: Dictionary=await ready_result
			_check(rejected.status[0]==0 and rejected.status[1]==1 and rejected.status[3]==1,"invalid initial support is rejected on GPU")
			_check(rejected.grid.all(func(v):return v==0.0),"valid run to invalid reset clears the previous grid")
			RenderingServer.call_on_render_thread(_rt_advance.bind(3,case.dt))
			var after: Dictionary=await ready_result
			_check(after.particle_hash==rejected.particle_hash and after.status==rejected.status,"invalid initial support remains frozen through queued steps")
			_check(after.grid_hash==rejected.grid_hash,"invalid initial support cannot resurrect old grid data")
		RenderingServer.call_on_render_thread(_gpu.close)
		await process_frame
	_results.checks=_checks;_results.failures=_failures
	FileAccess.open("res://docs/milestone/evidence-momentum-gpu/results.json",FileAccess.WRITE).store_string(JSON.stringify(_results,"  ")+"\n")
	print("MOMENTUM_MOTION_GPU checks=%d failures=%d"%[_checks,_failures])
	quit(1 if _failures else 0)

func _rt_initialize(case: Dictionary) -> void:
	_gpu.initialize(case);_rt_snapshot()

func _rt_reset(particles: Array) -> void:
	var values:=PackedFloat32Array()
	for p in particles:values.append_array(PackedFloat32Array(p))
	_gpu.reset(values);_rt_snapshot()

func _rt_advance(count: int,dt: float) -> void:
	var accepted: bool=_gpu.advance(count,dt)
	var result:=_serialize(_gpu.snapshot());result.accepted_submission=accepted
	ready_result.emit.call_deferred(result)

func _rt_snapshot() -> void:
	ready_result.emit.call_deferred(_serialize(_gpu.snapshot()))

func _serialize(raw: Dictionary) -> Dictionary:
	var bytes: PackedByteArray=raw.particles
	var mass:=PackedByteArray()
	for i in bytes.size()/80:mass.append_array(bytes.slice(i*80+12,i*80+16))
	return {"particles":Array(bytes.to_float32_array()),"particle_hash":_hash(bytes),"mass_hash":_hash(mass),"grid":Array(raw.grid),"grid_hash":_hash(raw.grid.to_byte_array()),"status":Array(raw.status)}

func _hash(bytes: PackedByteArray) -> String:
	var h:=HashingContext.new();h.start(HashingContext.HASH_SHA256);h.update(bytes);return h.finish().hex_encode()

func _check(ok: bool,message: String) -> void:
	_checks+=1
	if ok:print("ok: "+message)
	else:
		_failures+=1;push_error(message)
