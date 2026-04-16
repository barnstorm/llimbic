extends SceneTree
## test/test_somatic.gd — Verify somatic stream emits tags from Hebbian quality neurons

var _frame: int = 0
var _done: bool = false

func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	get_root().add_child(main)

func _process(delta: float) -> bool:
	_frame += 1
	if _frame < 10:
		return false
	if _done:
		return true
	_done = true
	_run_test()
	return true

func _run_test() -> void:
	print("\n========== SOMATIC STREAM TEST ==========\n")

	# Find Hugo
	var npcs: Array = get_root().get_tree().get_nodes_in_group("npcs")
	var hugo: Node = null
	for npc in npcs:
		if npc.npc_name == "Hugo":
			hugo = npc
			break

	if hugo == null or hugo.brain == null:
		print("ERROR: Hugo not found")
		return

	var brain = hugo.brain
	var l1 = brain.layer1

	# Check network has quality neurons
	var net = l1._network
	var quality_count: int = 0
	for neuron in net.neurons:
		if neuron["type"] == "quality":
			quality_count += 1
	print("Quality neurons: %d" % quality_count)
	print("Total neurons: %d" % net.neurons.size())
	print("Total connections: %d" % net.connections.size())

	# Check arousal neuron exists
	var arousal: float = net.get_activation("drive_arousal")
	print("Arousal neuron: %.1f" % arousal)

	# Run a few update ticks to let propagation fire
	for i in range(20):
		l1.update(0.016)

	# Get somatic tags
	var tags: Array = l1.get_somatic_tags()
	print("\nSomatic tags after 20 ticks:")
	for tag in tags:
		print("  %s" % tag)

	# Now stress the being — drop energy, raise hunger
	l1.energy = 20.0
	l1.hunger = 85.0
	l1.safety = 30.0
	for i in range(30):
		l1.update(0.016)

	tags = l1.get_somatic_tags()
	print("\nSomatic tags under stress (energy=20, hunger=85, safety=30):")
	for tag in tags:
		print("  %s" % tag)

	# Calm the being
	l1.energy = 90.0
	l1.hunger = 10.0
	l1.safety = 95.0
	for i in range(30):
		l1.update(0.016)

	tags = l1.get_somatic_tags()
	print("\nSomatic tags when calm (energy=90, hunger=10, safety=95):")
	for tag in tags:
		print("  %s" % tag)

	# Show quality neuron activations
	print("\nTop quality neuron activations:")
	var qualities: Array = []
	for neuron in net.neurons:
		if neuron["type"] == "quality" and neuron["activation"] > 15.0:
			qualities.append({"tag": neuron.get("tag_text", ""), "act": neuron["activation"], "regions": neuron.get("regions", [])})
	qualities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["act"] > b["act"])
	for q in qualities.slice(0, 10):
		print("  %s = %.1f  regions=%s" % [q["tag"], q["act"], str(q["regions"])])

	# Debug state
	var debug: Dictionary = l1.get_somatic_debug()
	print("\nCompound quality neurons: %d" % debug.get("compound_count", 0))

	print("\n========== END ==========\n")
