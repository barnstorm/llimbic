extends Node
## res://scripts/world_object_registry.gd — Persistent world object registry (autoload)
## Each object is a Dictionary with: id, name, type, position, location, state, owner, properties, discoverable, role_affinity
## Items (type="item") are takeable world objects with consume_effects.

var objects: Dictionary = {}  # id -> Dictionary
var _item_counter: int = 0  # for generating unique IDs when dropping items

func _ready() -> void:
	_populate_initial_objects()
	_populate_world_items()
	print("[WorldObjectRegistry] Registered %d world objects (incl. items)." % objects.size())

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
