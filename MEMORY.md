# Memory

## Task 1: World, Navigation & Characters

### What worked
- `Image.load_from_file()` works for reading the collision map PNG at runtime, even though Godot warns about export compatibility. The image loads correctly in both headless and display modes.
- AStar2D grid builds quickly (11936 walkable tiles from 140x100 map). 4-directional connectivity is sufficient for the tile grid.
- RPG Maker VX Ace sprite sheets: first character is top-left 3x4 block (3 cols x 4 rows). Row order: down=0, left=1, right=2, up=3. Each frame is 48x48. AtlasTexture regions work perfectly for extracting individual frames.
- Camera2D with `position_smoothing_enabled` + `limit_*` properties handles smooth follow and map-bounds clamping without custom code.
- `--write-movie` with `DISPLAY=:0` works on this system (lavapipe software renderer). Headless mode crashes when trying to render textures with `--write-movie`.

### Technical details
- Collision map: 140x100 grayscale, white(255)=blocked, black(0)=walkable. 2064 blocked tiles, 11936 walkable.
- TMX spawn positions (first 8): all in upper portion of map inside buildings. Spawn tiles are verified walkable.
- Player start position: world (2240, 1600) = tile (70, 50), confirmed walkable.
- `NavigationManager.astar` may be null during `_initialize()` in test harness — autoload `_ready()` fires after `_initialize()`. Check availability in `_process()` instead.

### Autoload access pattern
- Cannot reference autoloads by name in SceneTree scripts (quirk). Must iterate `get_tree().root.get_children()` and match by `.name`.
- In runtime scripts attached to scene nodes, same pattern works: iterate `get_tree().root.get_children()`.

### Character sprite setup
- SpriteFrames built programmatically with AtlasTexture per frame
- Animation names: `walk_down`, `walk_left`, `walk_right`, `walk_up`, `idle_down`, etc.
- Walk speed: 6 FPS, idle: 1 FPS (single frame)
- NPC character sheets: Character_RM_002 through Character_RM_009 assigned to 8 NPCs

### NPC names and roles
- Edith (Baker), Roland (Guard), Ivy (Herbalist), Felix (Courier)
- Greta (Blacksmith), Mabel (Gossip), Aldric (Farmer), Hugo (Innkeeper)
