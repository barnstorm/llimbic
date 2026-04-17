extends RefCounted
## res://scripts/inventory.gd — Generic container for items
## NPCs, players, shelves, chests, locations — anything that holds things.

var items: Array[Dictionary] = []  # [{id, name, category, quantity}]
var capacity: int = 5

func _init(max_slots: int = 5) -> void:
	capacity = max_slots

func add(item_id: String, item_name: String = "", category: String = "", quantity: int = 1) -> int:
	## Add items. Returns how many were actually added (may be less if full).
	if item_id == "":
		return 0
	# Try to stack with existing
	for item in items:
		if item["id"] == item_id:
			item["quantity"] += quantity
			return quantity
	# New slot
	if items.size() >= capacity:
		return 0
	items.append({
		"id": item_id,
		"name": item_name if item_name else item_id,
		"category": category,
		"quantity": quantity,
	})
	return quantity

func remove(item_id: String, quantity: int = 1) -> int:
	## Remove items. Returns how many were actually removed.
	for i in range(items.size()):
		if items[i]["id"] == item_id:
			var have: int = items[i]["quantity"]
			var take: int = mini(have, quantity)
			items[i]["quantity"] -= take
			if items[i]["quantity"] <= 0:
				items.remove_at(i)
			return take
	return 0

func has(item_id: String, quantity: int = 1) -> bool:
	for item in items:
		if item["id"] == item_id and item["quantity"] >= quantity:
			return true
	return false

func count(item_id: String) -> int:
	for item in items:
		if item["id"] == item_id:
			return item["quantity"]
	return 0

func is_full() -> bool:
	return items.size() >= capacity

func is_empty() -> bool:
	return items.size() == 0

func total_items() -> int:
	var total: int = 0
	for item in items:
		total += item["quantity"]
	return total

func get_items() -> Array[Dictionary]:
	return items

func get_item_ids() -> Array[String]:
	var ids: Array[String] = []
	for item in items:
		ids.append(item["id"])
	return ids

func get_display_list() -> Array[String]:
	## Human-readable list: ["Bread (x3)", "Ale"]
	var result: Array[String] = []
	for item in items:
		if item["quantity"] > 1:
			result.append("%s (x%d)" % [item["name"], item["quantity"]])
		else:
			result.append(item["name"])
	return result

func transfer_to(other: RefCounted, item_id: String, quantity: int = 1) -> int:
	## Move items to another inventory. Returns how many moved.
	if not has(item_id):
		return 0
	var available: int = count(item_id)
	var to_move: int = mini(available, quantity)
	# Find the item data for name/category
	var item_name: String = item_id
	var item_cat: String = ""
	for item in items:
		if item["id"] == item_id:
			item_name = item["name"]
			item_cat = item["category"]
			break
	var added: int = other.add(item_id, item_name, item_cat, to_move)
	if added > 0:
		remove(item_id, added)
	return added

func clear() -> void:
	items.clear()

func to_dict() -> Array[Dictionary]:
	## Serialize for snapshots/saving.
	return items.duplicate(true)

func from_dict(data: Array) -> void:
	## Load from serialized data.
	items.clear()
	for entry in data:
		if entry is Dictionary and entry.has("id"):
			items.append({
				"id": entry.get("id", ""),
				"name": entry.get("name", entry.get("id", "")),
				"category": entry.get("category", ""),
				"quantity": entry.get("quantity", 1),
			})
