extends SceneTree
## Quick debug: check quality neuron activations under stress conditions

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

	var npcs: Array = get_root().get_tree().get_nodes_in_group("npcs")
	var hugo: Node = null
	for npc in npcs:
		if npc.npc_name == "Hugo":
			hugo = npc
			break
	if hugo == null:
		print("No Hugo")
		return true

	var l1 = hugo.brain.layer1
	var net = l1._network

	# Stress the being hard
	l1.energy = 15.0
	l1.hunger = 90.0
	l1.safety = 20.0
	l1.frustration = 0.8

	# Run 100 ticks (about 1.6 seconds at 60fps)
	for i in range(100):
		l1.update(0.016)

	print("\n=== QUALITY ACTIVATIONS UNDER STRESS ===")
	var all_q: Array = []
	for neuron in net.neurons:
		if neuron["type"] == "quality":
			all_q.append({"tag": neuron.get("tag_text", ""), "act": neuron["activation"]})
	all_q.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["act"] > b["act"])
	for q in all_q:
		var marker: String = " ***" if q["act"] >= 40.0 else ""
		print("  %-15s %.1f%s" % [q["tag"], q["act"], marker])

	print("\nSomatic tags: %s" % str(l1.get_somatic_tags()))
	print("Arousal: %.1f" % (net.get_activation("drive_arousal")))

	# Run 100 more to really cook
	for i in range(100):
		l1.update(0.016)
	print("\nAfter 200 ticks:")
	print("Somatic tags: %s" % str(l1.get_somatic_tags()))

	all_q.clear()
	for neuron in net.neurons:
		if neuron["type"] == "quality" and neuron["activation"] >= 40.0:
			all_q.append({"tag": neuron.get("tag_text", ""), "act": neuron["activation"]})
	all_q.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["act"] > b["act"])
	print("\nAbove threshold (40):")
	for q in all_q:
		print("  %-15s %.1f" % [q["tag"], q["act"]])

	return true
