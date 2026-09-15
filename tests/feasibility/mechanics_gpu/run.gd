extends "res://tests/feasibility/momentum_gpu/run.gd"
func _initialize() -> void:
	_gpu_path="res://tools/feasibility/mechanics_gpu/gpu.gd"
	_cases_path="res://tests/feasibility/mechanics_gpu/cases.json"
	_results_path="res://docs/milestone/evidence-mechanics-gpu/results.json"
	super._initialize()

func _run() -> void:
	var cases: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(_cases_path))
	for case in cases.cases:
		_gpu=load(_gpu_path).new();RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
		var initial: Dictionary=await ready_result
		_check(initial.status[0]==0 and initial.status[1]==0,"%s initial state admitted"%case.name)
		var result:={"name":case.name,"initial":initial,"snapshots":[]}
		var attempted:=0
		var previous:=initial
		for expected in case.snapshots:
			RenderingServer.call_on_render_thread(_rt_advance.bind(int(expected.attempted)-attempted,case.dt))
			var state: Dictionary=await ready_result
			_check(state.status[0]==expected.ticks and bool(state.status[1])==expected.halted,"%s attempted%d GPU acceptance"%[case.name,expected.attempted])
			_check(state.mass_hash==initial.mass_hash,"%s particle mass bytes unchanged"%case.name)
			if expected.halted:
				_check(state.particle_hash==previous.particle_hash and state.ledger_hash==previous.ledger_hash,"rejected mechanics commits neither particles nor external ledger")
				_check(state.grid_hash==previous.grid_hash,"rejected mechanics snapshot rebuilds authoritative grid without candidate forces")
				_check(state.status[3]==4 and state.attempt_meta[1]==0,"plane crossing has explicit rejection status")
				_check(state.nodes.any(func(node):return node["values"][21]!=0.0),"rejected attempt actually computed nonzero wall impulse")
			result.snapshots.append(state);previous=state;attempted=int(expected.attempted)
		var final: Dictionary=result.snapshots[-1]
		for schedule in [[1],[3],[7,2,5,1,9]]:
			RenderingServer.call_on_render_thread(_rt_reset.bind(case.initial_particles));await ready_result
			var total:=0;var part:=0
			while total<case.steps:
				var count:=mini(schedule[part%schedule.size()],int(case.steps)-total)
				RenderingServer.call_on_render_thread(_gpu.advance.bind(count,case.dt));total+=count;part+=1
			RenderingServer.call_on_render_thread(_rt_snapshot)
			var grouped: Dictionary=await ready_result
			_check(grouped.particle_hash==final.particle_hash and grouped.audit_hash==final.audit_hash and grouped.status==final.status,"%s batches%s preserve particle/ledger/attempt bytes"%[case.name,schedule])
		_results.cases.append(result)
		if case.name=="plane_apic":
			var bad: Array=case.initial_particles.duplicate(true);bad[0][1]=0.15
			RenderingServer.call_on_render_thread(_rt_reset.bind(bad));var invalid: Dictionary=await ready_result
			_check(invalid.status[0]==0 and invalid.status[1]==1 and invalid.status[3]==4,"invalid initial half-space is rejected")
			_check(invalid.grid.all(func(v):return v==0.0) and invalid.ledger.all(func(v):return v==0.0) and invalid.nodes.is_empty(),"invalid reset clears previous grid and all mechanics ledgers")
			RenderingServer.call_on_render_thread(_rt_advance.bind(3,case.dt));var after: Dictionary=await ready_result
			_check(after.particle_hash==invalid.particle_hash and after.audit_hash==invalid.audit_hash and after.grid_hash==invalid.grid_hash,"invalid reset remains frozen through queued forced steps")
		RenderingServer.call_on_render_thread(_gpu.close);await process_frame
	_results.checks=_checks;_results.failures=_failures
	FileAccess.open(_results_path,FileAccess.WRITE).store_string(JSON.stringify(_results,"  ")+"\n")
	print("MECHANICS_GPU checks=%d failures=%d"%[_checks,_failures]);quit(1 if _failures else 0)

func _serialize(raw: Dictionary) -> Dictionary:
	var result:=super._serialize(raw)
	var bytes: PackedByteArray=raw.audit;var values:=bytes.to_float32_array()
	result.ledger=Array(values.slice(0,40));result.ledger_hash=_hash(bytes.slice(0,160))
	result.attempt_meta=Array(values.slice(40,44));result.audit_hash=_hash(bytes)
	var nodes:=[]
	for i in (values.size()-44)/28:
		if values[44+i*28+3]>0.0:nodes.append({"index":i,"values":Array(values.slice(44+i*28,44+(i+1)*28))})
	result.nodes=nodes;return result
