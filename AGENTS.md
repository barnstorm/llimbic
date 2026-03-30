Use the `$godogen` skill to generate or update this game from a natural language description.

This file is the Codex session template. The Claude Code equivalent lives in `CLAUDE.md`/`game.md` and invokes the same skill as `/godogen`.

Visual quality is the top priority. Example failures:
- Generating a detailed image then shrinking it to a tile - details become tiny and clunky. Generate with shapes appropriate for the target size.
- Tiling textures where a single high-quality drawn background is needed
- Using sprite sheets for fire, smoke, or water instead of procedural particles or shaders

# Status Updates

If the user is connected through an external channel or wants asynchronous progress, keep updates concise and include absolute paths for screenshots and videos when useful.

## godogen orchestrator

1. After creating `PLAN.md`, summarize the plan and point to `reference.png`.
2. After each task, summarize the result and visual QA verdict (pass/fail, key issues, rebuilds triggered), and point to the best screenshot.
3. After all tasks, summarize the completed game and point to the final video if one was generated.

# Project Structure

Game projects follow this layout once `$godogen` runs:

```text
project.godot          # Godot config: viewport, input maps, autoloads
reference.png          # Visual target - art direction reference image
STRUCTURE.md           # Architecture reference: scenes, scripts, signals
PLAN.md                # Task DAG - Goal/Requirements/Verify/Status per task
ASSETS.md              # Asset manifest with art direction and paths
MEMORY.md              # Accumulated discoveries from task execution
scenes/
  build_*.gd           # Headless scene builders (produce .tscn)
  *.tscn               # Compiled scenes
scripts/*.gd           # Runtime scripts
test/
  test_task.gd         # Per-task visual test harness (overwritten each task)
  presentation.gd      # Final cinematic video script
assets/                # gitignored - img/*.png, glb/*.glb
screenshots/           # gitignored - per-task frames
visual-qa/*.md         # Gemini vision QA reports
```

The working directory is the project root. Never `cd`; use relative paths for all commands.

## Limitations

- No audio support
- No animated GLBs - static models only
