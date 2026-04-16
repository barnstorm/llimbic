"""
Human control interface for NPC adventure commands.

Lets a human type commands like a text adventure to control any NPC.
Commands go through the same parse → push protocol as the AI model.

Usage:
    python human_control.py [--record training_data.jsonl]

Connect to the L3 server WebSocket, pick an NPC, see their perception,
type commands. Optionally record perception→command pairs as training data.
"""

import asyncio
import json
import sys
import os
import time
import readline  # enables arrow-key history in input()

# Add server dir to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from command_parser import parse_command_output
from command_model import _format_perception, SYSTEM_PROMPT

try:
    import websockets
except ImportError:
    print("pip install websockets")
    sys.exit(1)


HELP_TEXT = """
=== Adventure Commands ===
  GO TO <location|entity>       Move somewhere
  APPROACH <entity>             Get closer to someone
  LOOK AT <entity|object>       Watch something
  EXAMINE <object>              Inspect an object
  FLEE FROM <entity>            Run away
  WANDER [AT <location>]        Idle exploration
  WAIT                          Do nothing
  SAY "<text>" [TO <entity>]    Speak

=== Console Commands ===
  /npc <name>                   Switch to controlling a different NPC
  /look                         Show current perception
  /status                       Show drives, emotions, intentions
  /npcs                         List all registered NPCs
  /auto                         Return NPC to AI control
  /help                         Show this help
  /quit                         Exit
"""


class HumanController:
    """Interactive text adventure controller for NPCs."""

    def __init__(self, server_url="ws://127.0.0.1:8421/ws", record_path=None):
        self.server_url = server_url
        self.ws = None
        self.current_npc = None
        self.npc_states = {}  # npc_name -> last snapshot
        self.controlled_npcs = set()  # NPCs under human control (AI paused)
        self._req_counter = 0
        self._pending = {}  # req_id -> Future
        self._record_path = record_path
        self._record_file = None

    async def connect(self):
        self.ws = await websockets.connect(self.server_url)
        if self._record_path:
            self._record_file = open(self._record_path, "a")
            print(f"Recording training data to {self._record_path}")

    async def close(self):
        if self._record_file:
            self._record_file.close()
        if self.ws:
            await self.ws.close()

    async def _send_request(self, method, params):
        self._req_counter += 1
        req_id = f"human_{self._req_counter}"
        await self.ws.send(json.dumps({
            "id": req_id,
            "method": method,
            "params": params,
        }))
        # Wait for response
        while True:
            raw = await self.ws.recv()
            msg = json.loads(raw)
            if msg.get("id") == req_id:
                return msg.get("result", {})
            # It's a push message — store snapshot if relevant
            if msg.get("push"):
                npc = msg.get("npc", "")
                for cmd in msg.get("commands", []):
                    if cmd.get("cmd") == "set_thought" and npc == self.current_npc:
                        print(f"  [{npc} thinks: \"{cmd.get('text', '')}\"]")

    async def _send_command_to_npc(self, npc_name, command_str):
        """Parse a command and push it to the NPC via the thought loop."""
        state = self.npc_states.get(npc_name, {})
        context = {
            "npc_name": npc_name,
            "visible": state.get("visible", []),
            "visible_objects": state.get("visible_objects", []),
        }

        # Parse the command through the standard parser
        fake_raw = f"<think>\n(human command)\n</think>\n{command_str}"
        result = parse_command_output(fake_raw, context)

        if not result["command"]:
            print(f"  Could not parse command: {command_str}")
            return

        # Build push commands (same as thought_loop._run_thought_cycle step 4)
        commands = []

        # Push thought
        commands.append({
            "cmd": "set_thought",
            "text": f"[human] {command_str}",
        })

        # Push intentions
        for intention in result["intentions"]:
            commands.append({
                "cmd": "set_intention",
                "goal": intention["goal"],
                "location": intention["location"],
                "priority": intention.get("priority", 0.6),
                "reason": "human command",
            })

        # Push action biases
        if result["action_biases"]:
            commands.append({
                "cmd": "bias_action",
                "biases": result["action_biases"],
            })

        # Push trigger actions
        for trigger in result.get("trigger_actions", []):
            if trigger.get("type") == "speak":
                commands.append({
                    "cmd": "speak",
                    "text": trigger["text"],
                    "target": trigger.get("target"),
                })
            elif trigger.get("type") == "examine":
                commands.append({
                    "cmd": "examine",
                    "object_id": trigger.get("object_id"),
                    "target": trigger.get("target"),
                })

        # Push motor command
        commands.append({
            "cmd": "motor_command",
            "command": result["command"],
            "target": result["target"],
        })

        # Send via WebSocket as a push injection
        await self.ws.send(json.dumps({
            "id": f"human_push_{self._req_counter}",
            "method": "inject_commands",
            "params": {
                "npc_name": npc_name,
                "commands": commands,
            },
        }))

        print(f"  → {result['command']}")
        if result["action_biases"]:
            print(f"    biases: {result['action_biases']}")

    def _record_example(self, npc_name, command_str):
        """Record a perception→command pair as training data."""
        if not self._record_file:
            return
        state = self.npc_states.get(npc_name, {})
        # Build the same prompt the model would see
        context = {
            "npc_name": npc_name,
            "role": state.get("role", "villager"),
            "drives": state.get("drives", {}),
            "emotion_vector": state.get("emotion_vector", []),
            "location": state.get("location", "unknown"),
            "current_action": state.get("current_action", "idle"),
            "visible": state.get("visible", []),
            "visible_objects": state.get("visible_objects", []),
            "heard": state.get("heard", []),
            "recent_events": state.get("recent_events", []),
            "intentions_summary": "none",
            "beliefs_summary": "none",
            "recent_thoughts": [],
        }
        user_content = _format_perception(context)
        assistant_content = f"<think>\n(human player)\n</think>\n{command_str}"

        example = {
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
                {"role": "assistant", "content": assistant_content},
            ]
        }
        self._record_file.write(json.dumps(example) + "\n")
        self._record_file.flush()

    def _show_perception(self, npc_name):
        """Display what the NPC currently sees, hears, and knows."""
        state = self.npc_states.get(npc_name, {})
        if not state:
            print(f"  No state for {npc_name} yet. Wait for a snapshot.")
            return

        loc = state.get("location", "unknown")
        action = state.get("current_action", "idle")
        print(f"\n  === {npc_name} at {loc} ({action}) ===")

        # Drives
        drives = state.get("drives", {})
        print(f"  Energy {drives.get('energy', '?'):.0f}  "
              f"Hunger {drives.get('hunger', '?'):.0f}  "
              f"Social {drives.get('social_need', '?'):.0f}  "
              f"Safety {drives.get('safety', '?'):.0f}")

        # Visible
        visible = state.get("visible", [])
        print(f"\n  You see:")
        if visible:
            for v in visible:
                print(f"    {v.get('name', '?')} -- "
                      f"{v.get('distance', '?')} tiles {v.get('direction', '?')}")
        else:
            print(f"    (no one)")

        # Objects
        objects = state.get("visible_objects", [])
        print(f"  Nearby objects:")
        if objects:
            for o in objects:
                print(f"    {o.get('name', '?')} ({o.get('state', '?')})")
        else:
            print(f"    (none)")

        # Heard
        heard = state.get("heard", [])
        if heard:
            print(f"  You hear:")
            for h in heard:
                print(f"    {h.get('source', '?')}: \"{h.get('text', '')}\"")

        # Events
        events = state.get("recent_events", [])
        if events:
            print(f"  Recent: {'; '.join(str(e) for e in events[:3])}")

        print()

    def _show_status(self, npc_name):
        """Show drives, emotions, and intentions."""
        state = self.npc_states.get(npc_name, {})
        if not state:
            print(f"  No state for {npc_name}")
            return

        drives = state.get("drives", {})
        print(f"\n  === {npc_name} Status ===")
        for k, v in drives.items():
            bar = "█" * int(v / 5) + "░" * (20 - int(v / 5))
            print(f"  {k:15s} {bar} {v:.0f}")

        intentions = state.get("active_intentions", [])
        if intentions:
            print(f"\n  Intentions:")
            for i in intentions:
                print(f"    [{i.get('priority', 0):.1f}] {i.get('goal', '?')} at {i.get('location', '?')}")
        print()


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="Human NPC control console")
    parser.add_argument("--server", default="ws://127.0.0.1:8421/ws",
                        help="L3 server WebSocket URL")
    parser.add_argument("--record", default=None,
                        help="Path to record training data JSONL")
    parser.add_argument("--npc", default=None,
                        help="NPC to control on startup")
    args = parser.parse_args()

    ctrl = HumanController(server_url=args.server, record_path=args.record)

    print("Connecting to L3 server...")
    try:
        await ctrl.connect()
    except Exception as e:
        print(f"Failed to connect: {e}")
        return

    print("Connected!")
    print(HELP_TEXT)

    if args.npc:
        ctrl.current_npc = args.npc
        print(f"Controlling: {args.npc}")
        print("Type /look to see perception, then type commands.\n")

    # Background task to receive push messages and update state
    async def receive_loop():
        try:
            async for raw in ctrl.ws:
                msg = json.loads(raw)
                if msg.get("push"):
                    npc = msg.get("npc", "")
                    for cmd in msg.get("commands", []):
                        if cmd.get("cmd") == "set_thought" and npc == ctrl.current_npc:
                            if not cmd.get("text", "").startswith("[human]"):
                                print(f"\r  [{npc} thinks: \"{cmd.get('text', '')}\"]")
                                sys.stdout.write(f"{ctrl.current_npc}> ")
                                sys.stdout.flush()
                elif msg.get("method") == "state_broadcast":
                    # Store snapshot updates
                    params = msg.get("params", {})
                    npc = params.get("npc_name", "")
                    if npc:
                        ctrl.npc_states[npc] = params
        except Exception:
            pass

    recv_task = asyncio.create_task(receive_loop())

    # We need state snapshots. Register as a listener by sending
    # a subscribe request (or just wait for pushes from thought loop)
    # For now, we'll get state via state_update method

    try:
        while True:
            prompt = f"{ctrl.current_npc or '(no npc)'}> "
            try:
                line = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: input(prompt)
                )
            except EOFError:
                break

            line = line.strip()
            if not line:
                continue

            # Console commands
            if line.startswith("/"):
                parts = line.split(maxsplit=1)
                cmd = parts[0].lower()
                arg = parts[1] if len(parts) > 1 else ""

                if cmd == "/quit":
                    break
                elif cmd == "/help":
                    print(HELP_TEXT)
                elif cmd == "/npc":
                    if arg:
                        ctrl.current_npc = arg
                        print(f"  Now controlling: {arg}")
                        ctrl._show_perception(arg)
                    else:
                        print(f"  Current: {ctrl.current_npc or '(none)'}")
                        print(f"  Usage: /npc <name>")
                elif cmd == "/look":
                    if ctrl.current_npc:
                        # Request fresh state
                        result = await ctrl._send_request("get_npc_state", {
                            "npc_name": ctrl.current_npc
                        })
                        if result and not result.get("error"):
                            ctrl.npc_states[ctrl.current_npc] = result
                        ctrl._show_perception(ctrl.current_npc)
                    else:
                        print("  No NPC selected. Use /npc <name>")
                elif cmd == "/status":
                    if ctrl.current_npc:
                        result = await ctrl._send_request("get_npc_state", {
                            "npc_name": ctrl.current_npc
                        })
                        if result and not result.get("error"):
                            ctrl.npc_states[ctrl.current_npc] = result
                        ctrl._show_status(ctrl.current_npc)
                    else:
                        print("  No NPC selected.")
                elif cmd == "/npcs":
                    result = await ctrl._send_request("list_npcs", {})
                    npcs = result.get("npcs", [])
                    if npcs:
                        for npc in npcs:
                            marker = " <--" if npc == ctrl.current_npc else ""
                            print(f"  {npc}{marker}")
                    else:
                        print("  No NPCs registered yet.")
                elif cmd == "/auto":
                    if ctrl.current_npc:
                        ctrl.controlled_npcs.discard(ctrl.current_npc)
                        print(f"  {ctrl.current_npc} returned to AI control.")
                    else:
                        print("  No NPC selected.")
                else:
                    print(f"  Unknown command: {cmd}")
                continue

            # Adventure command
            if not ctrl.current_npc:
                print("  No NPC selected. Use /npc <name> first.")
                continue

            ctrl.controlled_npcs.add(ctrl.current_npc)
            await ctrl._send_command_to_npc(ctrl.current_npc, line)

            if ctrl._record_path:
                ctrl._record_example(ctrl.current_npc, line)
                print("  (recorded)")

    except KeyboardInterrupt:
        pass
    finally:
        recv_task.cancel()
        await ctrl.close()
        print("\nDisconnected.")


if __name__ == "__main__":
    asyncio.run(main())
