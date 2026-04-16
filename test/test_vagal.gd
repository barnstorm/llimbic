extends SceneTree
## test/test_vagal.gd — Verify vagal gate dynamics: transitions, hysteresis, dorsal shutdown

var _frame: int = 0
var _done: bool = false

func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)

func _process(delta: float) -> bool:
	_frame += 1
	if _frame < 5:
		return false
	if _done:
		return true
	_done = true
	_run_tests()
	return true

func _run_tests() -> void:
	print("\n========== VAGAL GATE TEST ==========\n")

	var npcs: Array = get_root().get_tree().get_nodes_in_group("npcs")
	var hugo: Node = null
	for npc in npcs:
		if npc.npc_name == "Hugo":
			hugo = npc
			break
	if hugo == null or hugo.brain == null:
		print("ERROR: Hugo not found")
		return

	var l1 = hugo.brain.layer1
	var net = l1._network

	# Verify vagal neurons exist
	var v_vent: float = net.get_activation("vagal_ventral")
	var v_symp: float = net.get_activation("vagal_sympathetic")
	var v_dors: float = net.get_activation("vagal_dorsal")
	print("Initial vagal state: ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [v_vent, v_symp, v_dors])
	print("Dominant: %s" % net.get_dominant_vagal())

	# --- Test 1: Calm baseline ---
	print("\n--- TEST 1: Calm baseline (high safety, high energy) ---")
	l1.energy = 85.0
	l1.safety = 90.0
	l1.hunger = 15.0
	l1.frustration = 0.05
	for i in range(200):
		l1.update(0.016)
	var vs: Dictionary = net.get_vagal_state()
	print("After 200 ticks calm: ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	print("Dominant: %s" % net.get_dominant_vagal())
	print("Somatic: %s" % str(l1.get_somatic_tags()))
	var approach_calm: float = l1.approach
	var flee_calm: float = l1.flee
	print("Actions: approach=%.2f flee=%.2f help=%.2f" % [l1.approach, l1.flee, l1.help])

	# --- Test 2: Threat onset (ventral → sympathetic) ---
	print("\n--- TEST 2: Threat onset (drop safety, raise frustration) ---")
	l1.safety = 20.0
	l1.frustration = 0.7
	var onset_ticks: int = 0
	for i in range(300):
		l1.update(0.016)
		onset_ticks += 1
		if net.get_dominant_vagal() == "sympathetic" and onset_ticks == i + 1:
			# First tick where sympathetic is dominant
			break
	vs = net.get_vagal_state()
	print("After %d ticks threat: ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [onset_ticks, vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	print("Dominant: %s" % net.get_dominant_vagal())
	print("Somatic: %s" % str(l1.get_somatic_tags()))
	print("Actions: approach=%.2f flee=%.2f help=%.2f" % [l1.approach, l1.flee, l1.help])

	# Let it run in sympathetic for a while
	for i in range(200):
		l1.update(0.016)
	vs = net.get_vagal_state()
	print("Sustained threat (200 more ticks): ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	print("Dominant: %s" % net.get_dominant_vagal())

	# --- Test 3: Recovery (sympathetic → ventral) — should be slower ---
	print("\n--- TEST 3: Recovery (restore safety) ---")
	l1.safety = 90.0
	l1.frustration = 0.1
	var recovery_ticks: int = 0
	for i in range(500):
		l1.update(0.016)
		recovery_ticks += 1
		if net.get_dominant_vagal() == "ventral":
			break
	vs = net.get_vagal_state()
	print("Recovery took %d ticks: ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [recovery_ticks, vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	print("Dominant: %s" % net.get_dominant_vagal())
	print("HYSTERESIS: onset=%d recovery=%d (recovery should be longer)" % [onset_ticks, recovery_ticks])

	# --- Test 4: Dorsal collapse ---
	print("\n--- TEST 4: Dorsal collapse (sustained inescapable stress) ---")
	l1.safety = 10.0
	l1.energy = 15.0
	l1.frustration = 0.9
	for i in range(500):
		l1.update(0.016)
	vs = net.get_vagal_state()
	print("After 500 ticks extreme stress: ventral=%.1f sympathetic=%.1f dorsal=%.1f" % [vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	print("Dominant: %s" % net.get_dominant_vagal())
	print("Somatic: %s" % str(l1.get_somatic_tags()))
	print("Actions: approach=%.2f flee=%.2f help=%.2f avoid=%.2f" % [l1.approach, l1.flee, l1.help, l1.avoid])

	# --- Test 5: Rung constraint (dorsal → ventral requires co-regulation) ---
	print("\n--- TEST 5: Dorsal recovery with co-regulation (social presence) ---")
	l1.safety = 90.0
	l1.energy = 80.0
	l1.frustration = 0.05
	# Simulate social presence — someone is with the being during recovery
	l1.set_context(12.0, true, false, "inn", 2)  # at home, 2 NPCs nearby
	var passed_through_sympathetic: bool = false
	var reached_ventral: bool = false
	var rung_ticks: int = 0
	for i in range(1500):
		l1.update(0.016)
		rung_ticks += 1
		var dom: String = net.get_dominant_vagal()
		if dom == "sympathetic" and not passed_through_sympathetic:
			passed_through_sympathetic = true
			vs = net.get_vagal_state()
			print("  Passed through sympathetic at tick %d: v=%.1f s=%.1f d=%.1f" % [rung_ticks, vs["ventral"], vs["sympathetic"], vs["dorsal"]])
		if dom == "ventral" and passed_through_sympathetic and not reached_ventral:
			reached_ventral = true
			vs = net.get_vagal_state()
			print("  Reached ventral at tick %d: v=%.1f s=%.1f d=%.1f" % [rung_ticks, vs["ventral"], vs["sympathetic"], vs["dorsal"]])
			break
	if not passed_through_sympathetic:
		vs = net.get_vagal_state()
		print("  Did not pass through sympathetic in 1500 ticks: v=%.1f s=%.1f d=%.1f" % [vs["ventral"], vs["sympathetic"], vs["dorsal"]])
	if not reached_ventral:
		vs = net.get_vagal_state()
		print("  Did not reach ventral in 1500 ticks: v=%.1f s=%.1f d=%.1f dom=%s" % [vs["ventral"], vs["sympathetic"], vs["dorsal"], net.get_dominant_vagal()])
	if passed_through_sympathetic and reached_ventral:
		print("  RUNG CONSTRAINT VERIFIED: dorsal → sympathetic → ventral")

	# --- Test 6: Vagal neurogenesis ---
	print("\n--- TEST 6: Vagal neurogenesis check ---")
	var debug: Dictionary = net.get_debug_state()
	var vagal_neurons: Array = []
	for n in debug.get("dynamic_neurons", []):
		if n.get("category", "") == "vagal":
			vagal_neurons.append(n)
	print("Vagal dynamic neurons spawned: %d" % vagal_neurons.size())
	for vn in vagal_neurons:
		print("  %s act=%.1f age=%d" % [vn["label"], vn["activation"], vn["age"]])
	print("Last neurogenesis event: %s" % str(net.last_neurogenesis_event))

	# Network stats
	print("\nNetwork: %d neurons, %d connections, %d dynamic" % [net.get_neuron_count(), net.get_connection_count(), net.get_dynamic_neuron_count()])

	print("\n========== END ==========\n")
