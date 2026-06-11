# Graph Report - .  (2026-05-14)

## Corpus Check
- 210 files · ~141,790 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 384 nodes · 288 edges · 172 communities (162 shown, 10 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 17 edges (avg confidence: 0.8)
- Token cost: 800 input · 1,500 output

## Community Hubs (Navigation)
- [[_COMMUNITY_jQueryThird-party Library|jQuery/Third-party Library]]
- [[_COMMUNITY_Battle UI Components|Battle UI Components]]
- [[_COMMUNITY_Docker & Architecture|Docker & Architecture]]
- [[_COMMUNITY_Player Simulation|Player Simulation]]
- [[_COMMUNITY_Game Master Editor|Game Master Editor]]
- [[_COMMUNITY_Damage Calculation|Damage Calculation]]
- [[_COMMUNITY_Battle Action Logic|Battle Action Logic]]
- [[_COMMUNITY_JSON Utilities|JSON Utilities]]
- [[_COMMUNITY_Timeline Action|Timeline Action]]
- [[_COMMUNITY_Main Entry|Main Entry]]
- [[_COMMUNITY_Timeline Event|Timeline Event]]
- [[_COMMUNITY_Decision Options|Decision Options]]
- [[_COMMUNITY_Pokemon Model|Pokemon Model]]
- [[_COMMUNITY_InterfaceMaster|InterfaceMaster]]
- [[_COMMUNITY_InterfaceMaster|InterfaceMaster]]

## God Nodes (most connected - your core abstractions)
1. `Player` - 20 edges
2. `PvPoke Project` - 20 edges
3. `$()` - 17 edges
4. `Te()` - 9 edges
5. `G()` - 8 edges
6. `GMEditorUtils` - 8 edges
7. `DamageCalculator` - 7 edges
8. `oe()` - 7 edges
9. `ce()` - 7 edges
10. `xe()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `Source Volume Mount` --shares_data_with--> `PvPoke Project`  [INFERRED]
  docker/docker-compose.yml → README.md
- `createInstance()` --calls--> `$()`  [INFERRED]
  tera/js/GameMaster.js → js/libs/jquery-3.3.1.min.js
- `modalWindow()` --calls--> `$()`  [INFERRED]
  tera/js/ModalWindow.js → js/libs/jquery-3.3.1.min.js
- `closeModalWindow()` --calls--> `$()`  [INFERRED]
  tera/js/ModalWindow.js → js/libs/jquery-3.3.1.min.js
- `PvPoke Project` --conceptually_related_to--> `Docker Web Service`  [INFERRED]
  README.md → docker/docker-compose.yml

## Hyperedges (group relationships)
- **MVC Architecture Components** — readme_gamemaster_js, readme_battle_js, readme_teamranker_js, readme_ranker_php, readme_mvc_architecture [EXTRACTED 1.00]
- **Docker Web Stack** — docker_web_service, docker_dockerfile, docker_src_volume, docker_pvpoke_port [EXTRACTED 1.00]

## Communities (172 total, 10 thin omitted)

### Community 0 - "jQuery/Third-party Library"
Cohesion: 0.07
Nodes (45): a(), ae(), be(), C(), ce(), ct(), de(), Ee() (+37 more)

### Community 1 - "Battle UI Components"
Cohesion: 0.07
Nodes (16): BattleHistogram(), interfaceObject(), closeModalWindow(), modalWindow(), Pokebox(), getDefaultMultiBattleSettings(), PokeMultiSelect(), submitSearchQuery() (+8 more)

### Community 2 - "Docker & Architecture"
Cohesion: 0.08
Nodes (30): Docker Dockerfile, PVPOKE_PORT Environment Variable, Source Volume Mount, Docker Web Service, Avoid Angular Decision, Avoid Third-party Libraries, Avoid User Accounts, Battle.js (+22 more)

### Community 4 - "Game Master Editor"
Cohesion: 0.18
Nodes (3): GMEditorUtils, GMEditorValidations, lastSavedGM

### Community 7 - "JSON Utilities"
Cohesion: 0.25
Nodes (5): fs, fullPath, json, output, path

## Knowledge Gaps
- **30 isolated node(s):** `DamageMultiplier`, `InterfaceMaster`, `InterfaceMaster`, `types`, `GMEditorValidations` (+25 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **10 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `$()` connect `Battle UI Components` to `jQuery/Third-party Library`, `Game Master Editor`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `PvPoke Project` (e.g. with `Docker Web Service` and `Source Volume Mount`) actually correct?**
  _`PvPoke Project` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 15 inferred relationships involving `$()` (e.g. with `createInstance()` and `submitSearchQuery()`) actually correct?**
  _`$()` has 15 INFERRED edges - model-reasoned connections that need verification._
- **What connects `DamageMultiplier`, `InterfaceMaster`, `InterfaceMaster` to the rest of the system?**
  _30 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `jQuery/Third-party Library` be split into smaller, more focused modules?**
  _Cohesion score 0.07 - nodes in this community are weakly interconnected._
- **Should `Battle UI Components` be split into smaller, more focused modules?**
  _Cohesion score 0.07 - nodes in this community are weakly interconnected._
- **Should `Docker & Architecture` be split into smaller, more focused modules?**
  _Cohesion score 0.08 - nodes in this community are weakly interconnected._