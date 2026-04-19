extends Node
## res://scripts/world_object_registry.gd — Persistent world object registry (autoload)
## Each object is a Dictionary with: id, name, type, position, location, state, owner, properties, discoverable, role_affinity
## Items (type="item") are takeable world objects with consume_effects.

var objects: Dictionary = {}  # id -> Dictionary
var _item_counter: int = 0  # for generating unique IDs when dropping items

func _ready() -> void:
	_populate_initial_objects()
	_populate_world_items()
	_populate_affordances()
	print("[WorldObjectRegistry] Registered %d world objects (incl. items)." % objects.size())

func _populate_affordances() -> void:
	## Attach `affordance` (INTERACT outcome) and `tactile` (TOUCH signature)
	## to selected objects. Both are open-ended dicts so the world can grow
	## new effects without touching the npc_brain handler.
	##
	## affordance fields:
	##   description: short felt text ("drew water from the well")
	##   drive_effects: {drive_name: delta} — applied to layer1
	##   quality_nudges: {quality_id: amount} — applied to Hebbian net
	##   memory_tags: array of tag strings for memory event
	##   state: optional new state to set after interact
	##
	## tactile fields:
	##   description: short text ("the iron is cold")
	##   quality_nudges: {quality_id: amount} — fires somatic qualities directly
	##
	# --- Bakery ---
	_set_affordance("bakery_oven_01", {
		"description": "warmth pours out of the oven, the air shimmers",
		"quality_nudges": {"q_warm": 35.0, "q_open": 8.0},
		"memory_tags": ["interact", "warmth"],
	})
	_set_tactile("bakery_oven_01", {
		"description": "the oven mouth is fierce hot — almost burning",
		"quality_nudges": {"q_warm": 45.0, "q_pressure": 8.0},
	})
	_set_affordance("bakery_basket_01", {
		"description": "the basket holds soft warm loaves",
		"quality_nudges": {"q_warm": 6.0, "q_settled": 5.0},
		"memory_tags": ["interact"],
	})
	_set_tactile("bakery_basket_01", {
		"description": "warm wicker, slightly rough",
		"quality_nudges": {"q_warm": 8.0, "q_settled": 4.0},
	})
	_set_tactile("bakery_flour_01", {
		"description": "the sack is soft and dry, flour sifts through the weave",
		"quality_nudges": {"q_dry": 15.0, "q_settled": 4.0},
	})

	# --- Guard Post ---
	_set_affordance("guard_weapon_rack_01", {
		"description": "you handle the swords — heavy, edge cold",
		"quality_nudges": {"q_cold": 12.0, "q_heavy": 8.0, "q_coiled": 5.0},
		"memory_tags": ["interact", "weapon"],
	})
	_set_tactile("guard_weapon_rack_01", {
		"description": "iron — cold, hard, unforgiving",
		"quality_nudges": {"q_cold": 25.0, "q_heavy": 6.0},
	})
	_set_affordance("guard_lantern_01", {
		"description": "the lantern hisses — flame steady, metal warm",
		"quality_nudges": {"q_warm": 10.0, "q_clear": 5.0},
		"memory_tags": ["interact"],
	})
	_set_tactile("guard_lantern_01", {
		"description": "warm metal, faintly oiled",
		"quality_nudges": {"q_warm": 12.0},
	})

	# --- Herbalist Shop ---
	_set_affordance("herb_drying_rack_01", {
		"description": "the herbs release their dry green scent",
		"quality_nudges": {"q_dry": 8.0, "q_settled": 5.0, "q_clear": 4.0},
		"memory_tags": ["interact", "herbal"],
	})
	_set_tactile("herb_drying_rack_01", {
		"description": "papery dry leaves, brittle stems",
		"quality_nudges": {"q_dry": 18.0},
	})
	_set_affordance("herb_mortar_01", {
		"description": "you grind — the pestle rasps, the bowl heats slightly",
		"quality_nudges": {"q_warm": 4.0, "q_pressure": 5.0, "q_clear": 3.0},
		"memory_tags": ["interact", "craft"],
	})
	_set_tactile("herb_mortar_01", {
		"description": "stone — cold, smooth-worn",
		"quality_nudges": {"q_cold": 12.0, "q_settled": 5.0},
	})
	_set_affordance("herb_remedy_shelf_01", {
		"description": "you sort the small jars — tinctures, balms",
		"quality_nudges": {"q_settled": 6.0},
		"memory_tags": ["interact"],
	})

	# --- Blacksmith ---
	_set_affordance("smith_anvil_01", {
		"description": "you strike — a clean ringing tone, vibration up the arm",
		"quality_nudges": {"q_pounding": 12.0, "q_buzzing": 6.0},
		"memory_tags": ["interact", "craft"],
	})
	_set_tactile("smith_anvil_01", {
		"description": "iron — cold, dense, immovable",
		"quality_nudges": {"q_cold": 30.0, "q_heavy": 8.0},
	})
	_set_affordance("smith_forge_01", {
		"description": "the forge breathes hot — even broken, embers smolder",
		"quality_nudges": {"q_warm": 25.0, "q_pressure": 8.0},
		"memory_tags": ["interact", "warmth"],
	})
	_set_tactile("smith_forge_01", {
		"description": "scorching — the forge throws heat in waves",
		"quality_nudges": {"q_warm": 50.0, "q_pressure": 10.0, "q_prickling": 8.0},
	})
	_set_tactile("smith_ingots_01", {
		"description": "iron and copper — cold, heavy, inert",
		"quality_nudges": {"q_cold": 18.0, "q_heavy": 10.0},
	})

	# --- Inn ---
	_set_affordance("inn_pantry_01", {
		"description": "you peer in — sacks, jars, smoked things hung",
		"quality_nudges": {"q_settled": 6.0, "q_full": 5.0},
		"memory_tags": ["interact"],
	})
	_set_affordance("inn_ledger_01", {
		"description": "the ledger lists guests — names, dates, notes",
		"quality_nudges": {"q_clear": 5.0, "q_settled": 4.0},
		"memory_tags": ["interact", "read"],
	})
	_set_tactile("inn_ledger_01", {
		"description": "smooth aged wood, paper soft from many hands",
		"quality_nudges": {"q_settled": 10.0, "q_warm": 4.0},
	})
	_set_affordance("inn_ale_barrel_01", {
		"description": "you tap the barrel — empty, hollow knock",
		"quality_nudges": {"q_hollow": 6.0},
		"memory_tags": ["interact"],
	})

	# --- Farm ---
	_set_affordance("farm_plow_01", {
		"description": "the plow handles fit your hands — wood worn smooth",
		"quality_nudges": {"q_settled": 6.0, "q_heavy": 4.0},
		"memory_tags": ["interact", "tool"],
	})
	_set_tactile("farm_plow_01", {
		"description": "old wood, smoothed by use",
		"quality_nudges": {"q_settled": 12.0, "q_warm": 4.0},
	})
	_set_affordance("farm_seed_storage_01", {
		"description": "you scoop seed — small, hard, cool through the fingers",
		"quality_nudges": {"q_cold": 8.0, "q_settled": 5.0},
		"memory_tags": ["interact"],
	})
	_set_affordance("farm_trough_01", {
		"description": "you dip — cold water, surface breaking",
		"drive_effects": {"hunger": -3.0, "energy": 4.0},
		"quality_nudges": {"q_cold": 20.0, "q_clear": 6.0},
		"memory_tags": ["interact", "drink", "water"],
	})
	_set_tactile("farm_trough_01", {
		"description": "the water is cold, almost biting",
		"quality_nudges": {"q_cold": 30.0, "q_clear": 8.0},
	})

	# --- Market ---
	_set_affordance("market_stall_01", {
		"description": "you handle the goods — testing, weighing in the hand",
		"quality_nudges": {"q_settled": 4.0, "q_clear": 3.0},
		"memory_tags": ["interact"],
	})
	_set_affordance("market_goods_01", {
		"description": "trade goods — cloth, tools, small wares",
		"quality_nudges": {"q_settled": 4.0, "q_clear": 3.0},
		"memory_tags": ["interact"],
	})

	# --- Town Square ---
	_set_affordance("square_well_bucket_01", {
		"description": "you draw water — bucket comes up cold and full",
		"drive_effects": {"hunger": -5.0, "energy": 5.0},
		"quality_nudges": {"q_cold": 25.0, "q_clear": 8.0, "q_settled": 5.0},
		"memory_tags": ["interact", "drink", "water"],
	})
	_set_tactile("square_well_bucket_01", {
		"description": "wet rope, cold wood, water sloshing",
		"quality_nudges": {"q_cold": 30.0, "q_clear": 6.0},
	})
	_set_affordance("square_notice_board_01", {
		"description": "the notices: posted by hand, the town's voice",
		"quality_nudges": {"q_clear": 6.0, "q_settled": 3.0},
		"memory_tags": ["interact", "read"],
	})

	# --- Item tactile signatures ---
	# Bread is warm, ale cold, apples cool, remedies bitter-sharp
	for id in objects.keys():
		var obj: Dictionary = objects[id]
		if obj.get("type", "") != "item":
			continue
		var iid: String = obj.get("item_id", "")
		match iid:
			"bread":
				_set_tactile(id, {
					"description": "warm crust, soft yielding center",
					"quality_nudges": {"q_warm": 18.0, "q_settled": 6.0},
				})
			"ale":
				_set_tactile(id, {
					"description": "cool jug, faintly damp",
					"quality_nudges": {"q_cold": 14.0, "q_settled": 4.0},
				})
			"apple":
				_set_tactile(id, {
					"description": "cool, smooth-skinned, firm",
					"quality_nudges": {"q_cold": 8.0, "q_settled": 5.0, "q_clear": 3.0},
				})
			"remedy":
				_set_tactile(id, {
					"description": "small bottle, cool glass, bitter-sharp scent",
					"quality_nudges": {"q_cold": 6.0, "q_clear": 8.0, "q_dry": 5.0},
				})

func _set_affordance(id: String, affordance: Dictionary) -> void:
	if objects.has(id):
		objects[id]["affordance"] = affordance

func _set_tactile(id: String, tactile: Dictionary) -> void:
	if objects.has(id):
		objects[id]["tactile"] = tactile

func get_affordance(id: String) -> Dictionary:
	## Returns affordance dict for an object, or empty if none.
	return objects.get(id, {}).get("affordance", {})

func get_tactile(id: String) -> Dictionary:
	## Returns tactile dict for an object, or empty if none.
	return objects.get(id, {}).get("tactile", {})

func _populate_world_items() -> void:
	## Place actual takeable items in the world near relevant fixtures.
	var food_fx: Dictionary = {"hunger": -30.0, "energy": 5.0}
	var drink_fx: Dictionary = {"hunger": -10.0, "energy": 15.0}
	var remedy_fx: Dictionary = {"energy": 25.0, "safety": 10.0}

	# --- Bakery: bread loaves near the oven ---
	_place_item("bakery_bread_01", "Bread", "bread", "food", Vector2(1680, 460), "bakery", food_fx)
	_place_item("bakery_bread_02", "Bread", "bread", "food", Vector2(1695, 485), "bakery", food_fx)
	_place_item("bakery_bread_03", "Bread", "bread", "food", Vector2(1710, 465), "bakery", food_fx)

	# --- Inn: ale jugs and bread at the bar ---
	_place_item("inn_ale_01", "Ale", "ale", "drink", Vector2(2530, 860), "inn", drink_fx)
	_place_item("inn_ale_02", "Ale", "ale", "drink", Vector2(2545, 870), "inn", drink_fx)
	_place_item("inn_bread_01", "Bread", "bread", "food", Vector2(2520, 880), "inn", food_fx)

	# --- Market: mixed goods on stalls ---
	_place_item("market_bread_01", "Bread", "bread", "food", Vector2(1500, 860), "market", food_fx)
	_place_item("market_apple_01", "Apple", "apple", "food", Vector2(1520, 850), "market", food_fx)
	_place_item("market_apple_02", "Apple", "apple", "food", Vector2(1535, 865), "market", food_fx)

	# --- Farm: apples ---
	_place_item("farm_apple_01", "Apple", "apple", "food", Vector2(650, 300), "farm", food_fx)
	_place_item("farm_apple_02", "Apple", "apple", "food", Vector2(670, 310), "farm", food_fx)
	_place_item("farm_apple_03", "Apple", "apple", "food", Vector2(660, 325), "farm", food_fx)

	# --- Herbalist: remedies on the shelf ---
	_place_item("herb_remedy_01", "Herbal Remedy", "remedy", "medicine", Vector2(515, 615), "herbalist_shop", remedy_fx)
	_place_item("herb_remedy_02", "Herbal Remedy", "remedy", "medicine", Vector2(530, 620), "herbalist_shop", remedy_fx)

func _place_item(id: String, display_name: String, item_id: String, category: String, pos: Vector2, location: String, effects: Dictionary) -> void:
	register_object({
		"id": id,
		"name": display_name,
		"item_id": item_id,
		"type": "item",
		"position": pos,
		"location": location,
		"state": "available",
		"owner": "",
		"properties": {"category": category},
		"consume_effects": effects,
		"discoverable": true,
		"role_affinity": [],
	})

func register_object(obj: Dictionary) -> void:
	var id: String = obj.get("id", "")
	if id == "":
		push_error("WorldObjectRegistry: object missing 'id'")
		return
	objects[id] = obj

func get_object(id: String) -> Dictionary:
	return objects.get(id, {})

func get_objects_at_location(location: String) -> Array:
	var result: Array = []
	for id in objects:
		var obj: Dictionary = objects[id]
		if obj.get("location", "") == location:
			result.append(obj)
	return result

func get_objects_by_type(type: String) -> Array:
	var result: Array = []
	for id in objects:
		var obj: Dictionary = objects[id]
		if obj.get("type", "") == type:
			result.append(obj)
	return result

func get_all_objects() -> Array:
	return objects.values()

func update_object_state(id: String, new_state: String) -> void:
	if objects.has(id):
		objects[id]["state"] = new_state

func remove_object(id: String) -> Dictionary:
	## Remove and return an object (used when items are picked up).
	if objects.has(id):
		var obj: Dictionary = objects[id]
		objects.erase(id)
		return obj
	return {}

func get_items_at_location(location: String) -> Array:
	## Get all takeable items at a location.
	var result: Array = []
	for id in objects:
		var obj: Dictionary = objects[id]
		if obj.get("location", "") == location and obj.get("type", "") == "item":
			result.append(obj)
	return result

func find_item_by_name(item_name: String, location: String) -> Dictionary:
	## Find a specific item by name at a location (case-insensitive).
	var lower: String = item_name.to_lower()
	for id in objects:
		var obj: Dictionary = objects[id]
		if obj.get("type", "") == "item" and obj.get("location", "") == location:
			if obj.get("name", "").to_lower() == lower or obj.get("item_id", "").to_lower() == lower:
				return obj
	return {}

func spawn_item(item_id: String, item_name: String, category: String, pos: Vector2, location: String, effects: Dictionary = {}) -> String:
	## Create a new item in the world (used when dropping items).
	_item_counter += 1
	var id: String = "item_%s_%d" % [item_id, _item_counter]
	register_object({
		"id": id,
		"name": item_name,
		"item_id": item_id,
		"type": "item",
		"position": pos,
		"location": location,
		"state": "on ground",
		"owner": "",
		"properties": {"category": category},
		"consume_effects": effects,
		"discoverable": true,
		"role_affinity": [],
	})
	return id

func _populate_initial_objects() -> void:
	# --- Bakery ---
	register_object({
		"id": "bakery_oven_01",
		"name": "Brick Oven",
		"type": "tool",
		"position": Vector2(1700, 450),
		"location": "bakery",
		"state": "working",
		"owner": "Edith",
		"properties": {"fuel": 80, "temperature": 350},
		"discoverable": true,
		"role_affinity": ["Baker"],
	})
	register_object({
		"id": "bakery_flour_01",
		"name": "Flour Sacks",
		"type": "supply",
		"position": Vector2(1730, 470),
		"location": "bakery",
		"state": "full",
		"owner": "Edith",
		"properties": {"quantity": 6},
		"discoverable": true,
		"role_affinity": ["Baker"],
	})
	register_object({
		"id": "bakery_basket_01",
		"name": "Bread Basket",
		"type": "container",
		"position": Vector2(1690, 480),
		"location": "bakery",
		"state": "empty",  # Non-default: creates discovery event
		"owner": "Edith",
		"properties": {"capacity": 20, "current": 0},
		"discoverable": true,
		"role_affinity": ["Baker"],
	})

	# --- Guard Post ---
	register_object({
		"id": "guard_weapon_rack_01",
		"name": "Weapon Rack",
		"type": "tool",
		"position": Vector2(2310, 450),
		"location": "guard_post",
		"state": "working",
		"owner": "Roland",
		"properties": {"swords": 3, "shields": 2},
		"discoverable": true,
		"role_affinity": ["Guard"],
	})
	register_object({
		"id": "guard_lantern_01",
		"name": "Guard Lantern",
		"type": "furniture",
		"position": Vector2(2330, 470),
		"location": "guard_post",
		"state": "working",
		"owner": "Roland",
		"properties": {"oil": 60},
		"discoverable": true,
		"role_affinity": ["Guard"],
	})

	# --- Herbalist Shop ---
	register_object({
		"id": "herb_drying_rack_01",
		"name": "Herb Drying Rack",
		"type": "tool",
		"position": Vector2(520, 580),
		"location": "herbalist_shop",
		"state": "working",
		"owner": "Ivy",
		"properties": {"herbs_drying": 12},
		"discoverable": true,
		"role_affinity": ["Herbalist"],
	})
	register_object({
		"id": "herb_mortar_01",
		"name": "Mortar and Pestle",
		"type": "tool",
		"position": Vector2(540, 600),
		"location": "herbalist_shop",
		"state": "working",
		"owner": "Ivy",
		"properties": {},
		"discoverable": true,
		"role_affinity": ["Herbalist"],
	})
	register_object({
		"id": "herb_remedy_shelf_01",
		"name": "Remedy Shelf",
		"type": "container",
		"position": Vector2(510, 610),
		"location": "herbalist_shop",
		"state": "full",
		"owner": "Ivy",
		"properties": {"remedies": 8},
		"discoverable": true,
		"role_affinity": ["Herbalist"],
	})

	# --- Blacksmith ---
	register_object({
		"id": "smith_anvil_01",
		"name": "Anvil",
		"type": "tool",
		"position": Vector2(1160, 580),
		"location": "blacksmith",
		"state": "working",
		"owner": "Greta",
		"properties": {},
		"discoverable": true,
		"role_affinity": ["Blacksmith"],
	})
	register_object({
		"id": "smith_forge_01",
		"name": "Forge",
		"type": "tool",
		"position": Vector2(1180, 600),
		"location": "blacksmith",
		"state": "broken",  # Non-default: creates discovery event
		"owner": "Greta",
		"properties": {"temperature": 0},
		"discoverable": true,
		"role_affinity": ["Blacksmith"],
	})
	register_object({
		"id": "smith_ingots_01",
		"name": "Metal Ingots",
		"type": "supply",
		"position": Vector2(1150, 610),
		"location": "blacksmith",
		"state": "full",
		"owner": "Greta",
		"properties": {"iron": 10, "copper": 4},
		"discoverable": true,
		"role_affinity": ["Blacksmith"],
	})

	# --- Inn ---
	register_object({
		"id": "inn_pantry_01",
		"name": "Pantry",
		"type": "container",
		"position": Vector2(2080, 610),
		"location": "inn",
		"state": "full",
		"owner": "Hugo",
		"properties": {"capacity": 50, "current": 35},
		"discoverable": true,
		"role_affinity": ["Innkeeper"],
	})
	register_object({
		"id": "inn_ledger_01",
		"name": "Guest Ledger",
		"type": "furniture",
		"position": Vector2(2110, 620),
		"location": "inn",
		"state": "working",
		"owner": "Hugo",
		"properties": {"guests_today": 3},
		"discoverable": true,
		"role_affinity": ["Innkeeper"],
	})
	register_object({
		"id": "inn_ale_barrel_01",
		"name": "Ale Barrel",
		"type": "supply",
		"position": Vector2(2070, 640),
		"location": "inn",
		"state": "empty",  # Non-default: creates discovery event
		"owner": "Hugo",
		"properties": {"capacity": 40, "current": 0},
		"discoverable": true,
		"role_affinity": ["Innkeeper"],
	})

	# --- Farm ---
	register_object({
		"id": "farm_plow_01",
		"name": "Plow",
		"type": "tool",
		"position": Vector2(2980, 580),
		"location": "farm",
		"state": "working",
		"owner": "Aldric",
		"properties": {},
		"discoverable": true,
		"role_affinity": ["Farmer"],
	})
	register_object({
		"id": "farm_seed_storage_01",
		"name": "Seed Storage",
		"type": "container",
		"position": Vector2(3010, 600),
		"location": "farm",
		"state": "full",
		"owner": "Aldric",
		"properties": {"wheat": 30, "barley": 15},
		"discoverable": true,
		"role_affinity": ["Farmer"],
	})
	register_object({
		"id": "farm_trough_01",
		"name": "Water Trough",
		"type": "resource",
		"position": Vector2(3000, 610),
		"location": "farm",
		"state": "working",
		"owner": "Aldric",
		"properties": {"water_level": 70},
		"discoverable": true,
		"role_affinity": ["Farmer"],
	})

	# --- Market ---
	register_object({
		"id": "market_stall_01",
		"name": "Market Stall",
		"type": "furniture",
		"position": Vector2(2760, 580),
		"location": "market",
		"state": "working",
		"owner": "",
		"properties": {},
		"discoverable": true,
		"role_affinity": ["Baker", "Blacksmith", "Farmer"],
	})
	register_object({
		"id": "market_goods_01",
		"name": "Trade Goods",
		"type": "supply",
		"position": Vector2(2780, 600),
		"location": "market",
		"state": "full",
		"owner": "",
		"properties": {"variety": 12},
		"discoverable": true,
		"role_affinity": [],
	})

	# --- Town Square ---
	register_object({
		"id": "square_well_bucket_01",
		"name": "Well Bucket",
		"type": "tool",
		"position": Vector2(1810, 790),
		"location": "well",
		"state": "working",
		"owner": "",
		"properties": {},
		"discoverable": true,
		"role_affinity": [],
	})
	register_object({
		"id": "square_notice_board_01",
		"name": "Notice Board",
		"type": "furniture",
		"position": Vector2(2090, 790),
		"location": "town_square",
		"state": "working",
		"owner": "",
		"properties": {"notices": 4},
		"discoverable": true,
		"role_affinity": [],
	})
