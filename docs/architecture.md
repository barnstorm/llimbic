# Cognitive Architecture — Data Flow Diagrams

## 1. System Overview

```mermaid
graph TB
    subgraph Client ["GDScript (Godot, every tick)"]
        HC[NPC Controller] --> Brain[NPC Brain]
        Brain --> L1[Layer 1: Hebbian Network]
        Brain --> L2[Layer 2: Emotion Projection]
        Brain --> L3[Layer 3: Executive Planner]
        Brain --> Mem[Memory System]
        Brain --> Inv[Inventory]
        Brain --> Perc[Perception]
        L1 --> HN[Hebbian Network]
        L1 --> SS[Somatic Stream]
        HN --> SS
    end

    subgraph Server ["Python Server (port 8421)"]
        TL[Thought Loop] --> CM[Command Model<br/>SmolLM3-3B :8423]
        TL --> L2S[L2 Limbic<br/>TinyLlama :8422]
        TL --> NS[NPC State]
        ChatM[Chat Model<br/>SmolLM3-3B :8424] --> CP[Command Parser]
    end

    subgraph Trace ["Trace Logger"]
        TJ[trace.jsonl]
    end

    HC -- "snapshot every 2s" --> NS
    TL -- "push commands" --> Brain
    Brain -- "chat/dialogue requests" --> ChatM
    TL --> TJ
    ChatM --> TJ
```

## 2. Per-Tick Client Loop

```mermaid
graph TD
    Tick["_physics_process(delta)"] --> Perc["update_perception()<br/>FOV + raycasting + hearing"]
    Perc --> L1Update["layer1.update(delta)"]

    L1Update --> Sensory["Set sensory neurons<br/>home/work/hour/npcs/stall/food"]
    Sensory --> Drift["Baseline drift<br/>energy ±, hunger +, social +, safety +"]
    Drift --> Propagate["Hebbian propagate<br/>contributions × 0.1, decay 0.998"]
    Propagate --> Learn{"Every 0.5s?"}
    Learn -- yes --> Hebbian["Hebbian learning<br/>co-active >70 → strengthen top 2"]
    Learn -- no --> Neuro
    Hebbian --> Neuro{"Every 2s?"}
    Neuro -- yes --> NG["Neurogenesis<br/>stress → novelty → reward → vagal"]
    Neuro -- no --> Somatic
    NG --> Somatic{"Every 0.25s?"}
    Somatic -- yes --> Emit["Somatic emit<br/>quality neurons → tags"]
    Somatic -- no --> Action

    Emit --> Action["select_action(delta)<br/>softmax over action neurons<br/>+ server biases"]
    Action --> Execute["Execute: move/idle/speak/examine"]
```

## 3. Hebbian Network — Neuron Types

```mermaid
graph LR
    subgraph Drives ["Drive Neurons (protected)"]
        DE[energy]
        DH[hunger]
        DS[social]
        DSF[safety]
    end

    subgraph Sensory ["Sensory Neurons (protected)"]
        SH[at_home]
        SW[at_work]
        SF[at_food]
        SN[nearby_npcs]
        SS[is_stalled]
    end

    subgraph Quality ["Quality Neurons (29 base + compounds)"]
        QT[tight]
        QL[loose]
        QH[heavy]
        QC[churning]
        QS[settled]
        QW[warm]
        QP[pounding]
        QE[empty_need]
        QX["compounds<br/>(neurogenesis)"]
    end

    subgraph Actions ["Action Neurons (baselined)"]
        AA[approach: 50]
        AV[avoid: 20]
        AO[observe: 30]
        AH[help: 20]
        AF[flee: 0]
    end

    subgraph Vagal ["Vagal Neurons (baselined)"]
        VV[ventral: 10]
        VS[sympathetic: 5]
        VD[dorsal: 2]
    end

    DH -- "+0.04" --> QC
    DH -- "+0.04" --> QH
    DH -- "-0.04" --> QS
    DE -- "-0.03" --> QH
    DSF -- "-0.03" --> QT
    DS -- "+0.03" --> QE

    QT -- "somatic" --> Tags["Somatic Tags<br/>gut:empty:churning<br/>chest:tight"]
    QC -- "somatic" --> Tags
    QS -- "somatic" --> Tags

    Drives --> Actions
    Sensory --> Quality
    VV -- "gates" --> Actions
```

## 4. Somatic Stream — Tag Emission

```mermaid
graph TD
    QN["Quality Neurons<br/>activation 0-100"] --> Thresh{"activation >= 40?"}
    Thresh -- yes --> Prob["Emission probability<br/>p = 0.2 + intensity×0.6<br/>± arousal×0.3"]
    Thresh -- no --> Skip[Skip]
    Prob --> Roll{"randf() <= p?"}
    Roll -- yes --> Region["Bind to region<br/>gut/chest/skin/muscles/<br/>head/throat/body"]
    Roll -- no --> Skip

    Region --> Suppress{"Threat suppression?<br/>flee>30 or safety<40"}
    Suppress -- suppressed --> Skip
    Suppress -- pass --> Concat["Concatenate<br/>region:quality:quality<br/>(max 3 per region)"]

    Concat --> Tags["Output tags<br/>['gut:empty:churning',<br/>'chest:tight',<br/>'body:settled']"]

    subgraph Conditioning ["Place/Entity Conditioning"]
        PM["Memory: place threat"] --> Phantom["Phantom activation<br/>nudge q_prickling, q_tight"]
        EM["Memory: entity threat"] --> Phantom
        CM["Memory: place comfort"] --> PhantomC["Nudge q_settled, q_warm"]
    end

    Phantom --> QN
    PhantomC --> QN
```

## 5. Snapshot → Server → Push Commands

```mermaid
sequenceDiagram
    participant C as NPC Controller
    participant NS as NPC State (server)
    participant TL as Thought Loop
    participant CM as Command Model :8423
    participant L2 as L2 Limbic :8422
    participant B as NPC Brain

    C->>NS: snapshot (every 2s)
    Note over NS: drives, somatic_tags, visible,<br/>heard, carried_items,<br/>available_items, location

    TL->>NS: should_think()?
    NS-->>TL: yes (urgency → 2-8s interval)

    TL->>NS: build_thought_context()
    NS-->>TL: full context dict

    TL->>L2: project(drives, events, emo_vec)
    L2-->>TL: updated emotion_vector

    TL->>CM: generate_command(context)
    Note over CM: _format_perception() →<br/>BEING, LOCATION, You feel,<br/>Carrying, Available here,<br/>You see, Commands list
    CM-->>TL: {thoughts, command,<br/>biases, triggers}

    TL->>L2: color_thought(thought_text)
    L2-->>TL: final emotion_vector

    TL->>B: push commands
    Note over B: update_emotion<br/>set_thought<br/>set_intention<br/>bias_action<br/>motor_command<br/>take/consume/drop/give
```

## 6. Command Model Prompt → Parse → Action

```mermaid
graph TD
    Context["Thought Context"] --> Format["_format_perception()"]

    Format --> Prompt["BEING: Innkeeper<br/>LOCATION: bakery<br/>DOING: idle<br/><br/>You feel: gut:empty, chest:tight<br/>Carrying: Bread, Ale<br/>Available here: Bread, Apple<br/><br/>You see: Mabel -- 3 tiles east<br/>You hear: (nothing)<br/>Nearby objects: Brick Oven<br/><br/>Recent: Walked to bakery<br/>Goal: go to bakery (0.6)<br/>Last thought: Need food<br/><br/>Commands: GO TO, TAKE, CONSUME...<br/>Think, then choose ONE action."]

    Prompt --> LLM["SmolLM3-3B<br/>port 8423"]

    LLM --> Raw["&lt;think&gt;<br/>Bread right here. Take some.<br/>&lt;/think&gt;<br/>TAKE Bread"]

    Raw --> Parser["command_parser.py"]

    Parser --> Think["thought: 'Bread right here'"]
    Parser --> Cmd["trigger: {type: take_item,<br/>item: 'Bread'}"]

    Cmd --> Push["Push to client"]
    Push --> Brain["npc_brain:<br/>world_registry.find_item()<br/>→ inventory.add()<br/>→ registry.remove_object()"]
```

## 7. Chat / Dialogue Flow

```mermaid
sequenceDiagram
    participant P as Player
    participant C as NPC Controller
    participant IS as Interaction System
    participant S as Layer3 Server :8421
    participant Chat as Chat Model :8424

    P->>C: interact (press E)
    C->>IS: _open_chat(npc)
    IS->>S: dialogue_v2 (packet)
    S->>Chat: _generate_chat(system, messages)
    Note over Chat: System: You are Hugo, Innkeeper.<br/>You feel: gut:empty, chest:tight<br/>Carrying: Bread, Ale<br/>Greet with one short sentence.
    Chat-->>S: "<think>A stranger...</think>Welcome."
    S->>S: _split_think_and_speech()
    S-->>IS: {utterance: "Welcome.",<br/>inner_thought: "A stranger..."}

    P->>IS: types message
    IS->>S: chat_v2 (packet + history + message)
    S->>Chat: _generate_chat(system, multi-turn)
    Note over Chat: System: perception + somatic<br/>History: [{user: "Hi"}, {asst: "Welcome"}]<br/>User: "Got food?"
    Chat-->>S: "<think>Has bread</think>Take some."
    S-->>IS: {utterance: "Take some.",<br/>inner_thought: "Has bread"}
    S->>S: trace_speech(npc, "chat_v2", ...)
```

## 8. Inventory Flow

```mermaid
graph TD
    subgraph World ["World Object Registry"]
        WI["Items at locations<br/>bakery_bread_01: Bread @ (1680,460)<br/>inn_ale_01: Ale @ (2530,860)"]
    end

    subgraph Snapshot ["Snapshot (every 2s)"]
        CI["carried_items:<br/>['Bread', 'Ale']"]
        AI["available_items:<br/>['Bread', 'Apple']"]
    end

    subgraph Prompt ["Command Model Prompt"]
        CP["Carrying: Bread, Ale<br/>Available here: Bread, Apple"]
    end

    subgraph Grammar ["GBNF Grammar"]
        TC["take-cmd: TAKE available-item<br/>consume-cmd: CONSUME carried-item<br/>drop-cmd: DROP carried-item<br/>give-cmd: GIVE carried-item TO entity"]
    end

    subgraph Execute ["NPC Brain Execution"]
        Take["TAKE:<br/>registry.find_item() →<br/>inventory.add() →<br/>registry.remove_object()"]
        Consume["CONSUME:<br/>inventory.remove() →<br/>apply_effects(category)<br/>food: hunger -30, energy +5<br/>drink: hunger -10, energy +15<br/>medicine: energy +25, safety +10"]
        Drop["DROP:<br/>inventory.remove() →<br/>registry.spawn_item(pos)"]
        Give["GIVE:<br/>inventory.remove() →<br/>action_override to target"]
    end

    WI --> AI
    CI --> CP
    AI --> CP
    CP --> Grammar
    Grammar --> Take
    Grammar --> Consume
    Grammar --> Drop
    Grammar --> Give
    Take --> WI
    Drop --> WI
```

## 9. Trace Logger — Event Types

```mermaid
graph LR
    subgraph Sources ["Event Sources"]
        TL["Thought Loop<br/>(every 2-8s per NPC)"]
        D["Dialogue<br/>(on player approach)"]
        CH["Chat<br/>(each player message)"]
        CO["Converse<br/>(NPC-to-NPC)"]
        SAY["SAY command<br/>(thought loop)"]
    end

    subgraph Trace ["trace_{ts}.jsonl"]
        T["type: thought<br/>───────────<br/>npc, role, location, hour<br/>somatic_tags, drives, vagal<br/>carrying, available_here<br/>visible, heard, objects<br/>intentions, beliefs<br/>recent_thoughts<br/>───────────<br/>thought (inner monologue)<br/>command, target<br/>action_biases<br/>trigger_actions<br/>raw model output<br/>inference_ms"]

        S["type: speech<br/>───────────<br/>npc, mode, location<br/>somatic_tags, carrying<br/>utterance, intent<br/>inner_thought<br/>───────────<br/>chat: player_message,<br/>  history, perception<br/>converse: speaker,<br/>  listener, listener_somatic<br/>say: target, text<br/>───────────<br/>inference_ms"]
    end

    TL --> T
    D --> S
    CH --> S
    CO --> S
    SAY --> S
```

## 10. Cadence Reference

```mermaid
gantt
    title Component Cadences (1 second = 1 unit)
    dateFormat X
    axisFormat %S

    section Per Tick (60fps)
    Perception          :a, 0, 1
    L1 Propagate        :b, 0, 1
    L1 Modulation       :c, 0, 1
    Action Selection    :d, 0, 1

    section Sub-second
    Somatic Emit (0.25s):e, 0, 4
    Hebbian Learn (0.5s):f, 0, 2

    section Seconds
    Snapshot Send (2s)  :g, 0, 8
    Neurogenesis (2s)   :h, 0, 8
    Thought Cycle (2-8s):i, 0, 16
    L2 Limbic (5s)      :j, 0, 20

    section Minutes
    L3 Replan (30 game-min) :k, 0, 60
```

## 11. Neurogenesis Cascade

```mermaid
graph TD
    Check{"Every 2s:<br/>check_neurogenesis()"} --> Stress{"Stress?<br/>frustration >75<br/>or sustained >3s"}
    Stress -- yes --> SN["Spawn stress neuron<br/>dyn_stress_{context}<br/>inhibit frustration (-0.1)<br/>boost observe (+0.05)"]
    Stress -- no --> Novelty{"Novelty?<br/>familiarity <30<br/>exposure >5s"}
    Novelty -- yes --> NN["Spawn novelty neuron<br/>dyn_novelty_{id}<br/>boost observe (+0.06)<br/>boost approach (+0.04)"]
    Novelty -- no --> Reward{"Reward?<br/>recent_reward >0"}
    Reward -- yes --> RN["Spawn reward neuron<br/>dyn_reward_{context}<br/>reinforce drive→action path"]
    Reward -- no --> Vagal{"Vagal?<br/>vagal+action<br/>co-active >4s"}
    Vagal -- yes --> VN["Spawn vagal bridge<br/>dyn_vagal_{state}_{action}<br/>wire vagal↔action"]
    Vagal -- no --> QNG{"Quality?<br/>co-active pair<br/>>8 times in 30s"}
    QNG -- yes --> QN["Spawn compound quality<br/>q_compound_{id}<br/>tag: parent_a:parent_b<br/>inherit regions + weights"]
    QNG -- no --> Done[Wait 2s]
```
