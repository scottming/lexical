# Cognitive Load Analysis of Lexical Patterns

How Lexical's codebase patterns reduce cognitive load, analyzed through five fundamental cognitive operations and four bridging mechanisms (from Barsalou's Perceptual Symbol Systems framework; see [cognitive-operations.md](https://github.com/scottming/scott-skills/blob/master/skills/code-design/references/cognitive-operations.md) for the full cognitive science foundation).

## The Five Cognitive Operations

Human code reading engages three **element operations** (what the brain does with each unit of code) and two **structural dimensions** (along which axis complexity grows).

```
Element operations (cognitive cost per unit):
  Enumerate ─── activate a concept: "what is this?"
  Compare ───── bind to a type: "A or B?"
  Simulate ──── run a causal chain: "if X, then what?"

Structural dimensions (along which axis complexity grows):
  Compose ───── more units at the same level (horizontal)
  Nest ─────── deeper abstraction levels (vertical)
```

Element operations have an inherent cost gradient: **Enumerate is nearly free, Compare is cheap at close range, Simulate is expensive** (bounded by ~4 items in working memory, Cowan 2001). Structural dimensions have **no inherent cost** — their cost depends entirely on which element operations they require internally:

- Good composition → reader only **enumerates** parts → low cost
- Good nesting → reader only **compares** layer interfaces → low cost
- Bad composition → reader must **simulate** all parts simultaneously → high cost
- Bad nesting → reader must **simulate** multiple stack frames → high cost

**Cost = element operation cost × structural complexity**, not structural complexity alone. This is why well-structured multi-layer code can be cheaper than "flat" code that forces simulation.

Four **bridging mechanisms** connect these operations:
- **Entrenchment**: repeated experience converts Simulate → Enumerate (the Nth time you see a pattern, you recognize it instead of tracing it)
- **Pattern completion**: good composition triggers automatic predictions about unseen parts (Barsalou 2009)
- **Isomorphism**: when nesting layers follow the same structural pattern, understanding one layer lets the reader predict the rest — pattern completion extended from horizontal to vertical (Bastos et al. 2012, Martins et al. 2015)
- **Productivity**: Compose × Nest together produce infinite expressiveness from finite modules (Barsalou 1999)

---

## Primary Strategy: Reduce Simulation Cost

Simulation is the dominant cognitive cost when reading code. Lexical's most frequently used technique is **severing the simulation chain** — splitting things that would need to be simulated together into independent pieces, so the reader only simulates one thing at a time.

### 1. Nested State Module — Sever "OTP protocol + business logic" simulation

Reading a typical GenServer requires **simultaneous** simulation of:
- OTP callback semantics (`{:noreply, state}` vs `{:reply, ...}` vs `{:stop, ...}`)
- How business state evolves
- Where side effects occur

Lexical splits this into two independent simulation chains:

```elixir
# Reading State module: simulate pure data transformations only
def on_nodeup(%State{} = state, node_name) do
  # Input state → output state. No {:noreply, ...} noise.
  %{state | status: :started}
end

# Reading GenServer: simulate dispatch only, no business logic
def handle_info({:nodeup, node, _}, %State{} = state) do
  state = State.on_nodeup(state, node)  # one call, no need to expand
  {:noreply, state}
end
```

**Cognitive effect**: One long simulation chain becomes two short, independent ones. Reading State requires no OTP knowledge; reading GenServer requires no business logic knowledge.

This is Lexical's **most frequently used technique** — found in **16+ GenServer/gen_statem pairs** across the codebase:

| Packaging | OTP module → State module |
|-----------|--------------------------|
| **Separate file** | `Lexical.Server` → `Server.State`, `RemoteControl.Build` → `Build.State`, `Project.Progress` → `Progress.State`, `Project.Diagnostics` → `Diagnostics.State`, `Search.Store` → `Store.State`, `Backends.Ets` → `Ets.State`, `Plugin.Runner.Coordinator` → `Coordinator.State` |
| **Nested in same file** | `Server.TaskQueue`, `Server.Project.Node`, `Server.Project.Intelligence`, `Document.Store`, `RemoteControl.ModuleMappings`, `RemoteControl.Commands.Reindex`, `RemoteControl.ProjectNode` |
| **Multiple companion modules** | `RemoteControl.Api.Proxy` → `BufferingState` / `ProxyingState` / `DrainingState` |
| **gen_event variant** | `Dispatch.PubSub` → nested `State` |

The sheer scale of this pattern is significant: after a new developer encounters it 3-4 times, their brain **entrenches** a situated conceptualization — "GenServer + State = dispatch vs logic separation." From that point on, seeing `State.on_xxx(state, ...)` triggers **pattern completion** rather than simulation. The 5th, 10th, 16th instance costs nearly zero to read.

### 2. Behaviour + `use` macro — Sever "framework understanding + implementation detail" simulation

```elixir
defmodule Detection.Alias do
  use Detection  # one-line declaration, no need to expand

  @impl Detection
  def detected?(analysis, position) do
    # only simulate this one function's logic
  end
end
```

`use Detection` does three things (registers behaviour, imports helpers, sets up callback), but the reader **does not need to expand it** to understand what this module does. The `@impl Detection` annotation further confirms "this is a callback implementation," preventing the reader from simulating "who calls this function?"

### 3. `with` linear pipeline — Eliminate branch simulation

```elixir
# apps/server/lib/lexical/server.ex
def handle_message(%_{} = request, %State{} = state) do
  with {:ok, handler} <- fetch_handler(request),
       {:ok, req} <- Convert.to_native(request) do
    TaskQueue.add(request.id, {handler, :handle, [req, state.configuration]})
  end
end
```

The reader's simulation path is **linear**: step1 → step2 → done. No need to maintain a branch tree in working memory. Each step's name (`fetch_handler`, `Convert.to_native`) tells **what** it does — no need to expand the function body to simulate **how**.

---

## Secondary Strategy: Reduce Enumeration Cost

Enumeration is the cheapest cognitive operation, but Lexical further reduces its cost by **colocating things that need to be enumerated**.

### @handlers list — Shrink enumeration scope from "entire codebase" to "5 lines"

```elixir
@handlers [
  Handlers.ReplaceRemoteFunction,
  Handlers.ReplaceWithUnderscore,
  Handlers.OrganizeAliases,
  Handlers.AddAlias,
  Handlers.RemoveUnusedAlias
]
```

"What code actions does this system support?" — enumerate these 5 lines, not search the codebase.

### @enforce_keys — Enumerate required fields

```elixir
@enforce_keys [:project, :cookie, :status]
defstruct [:project, :port, :cookie, :stopped_by, :started_by, :status]
```

"Which fields are required?" — enumerate `@enforce_keys`, rather than simulating all construction paths.

### @impl annotations — Enumerate callback boundaries

Without `@impl`, the reader must **compare** against the behaviour definition to determine which functions are callbacks and which are internal. With `@impl`, just enumerate the annotated functions. This **downgrades a compare operation to an enumerate operation**.

---

## Tertiary Strategy: Reduce Comparison Cost

### Uniform interfaces — Eliminate "this vs that" structural comparison

The Translatable protocol gives all completion candidate types the same `translate/3` interface. Once the reader understands one implementation, they understand the **shape** of all implementations — only **content** differences need comparison, not **structural** differences.

```elixir
# Every implementation has identical signature — only the body differs
defimpl Translatable, for: Candidate.Function do
  def translate(function, builder, env), do: ...
end

defimpl Translatable, for: Candidate.Macro do
  def translate(macro, builder, env), do: ...
end
```

### `%Struct{} = param` — Type comparison at the signature

```elixir
# apps/remote_control/lib/lexical/remote_control/code_intelligence/entity.ex
def resolve(%Analysis{} = analysis, %Position{} = position) do ...
```

The reader doesn't need to enter the function body and simulate data flow to confirm input types. At the signature: expected Analysis and Position, receiving the right types? Done. One **comparison** at the call site, zero **simulation** required.

---

## Higher-Order Operations: Compose and Nest

Lexical handles structural dimensions more subtly. A brief overview of two representative examples (see deep dives below for full treatment):

### Compose — Proto DSL's layered macro design

```
deftype = Json.build + Inspect.build + Access.build + Struct.build + Parse.build + Meta.build
defrequest = deftype + Message.build + Jason.Encoder
```

Each layer only needs to understand its own input/output, not the other layers' implementations. The composition cost is **encapsulated** inside macros — the user sees a single `deftype [name: string(), ...]`.

### Nest — Convertible protocol's automatic nesting traversal

```elixir
# Any fallback recursively converts struct fields
def to_native(%_struct{} = struct, context_document) do
  struct |> Map.from_struct() |> Helpers.apply(&Convertible.to_native/2, context_document)
end
```

The reader doesn't need to think about nesting depth — the protocol framework traverses for them. Nesting cognitive load is absorbed by the framework, leaving the reader with a flat mental model.

---

## Summary

| Element Operation | Lexical's Reduction Strategy | Frequency | Entrenchment effect |
|--------------------|------------------------------|-----------|-------------------|
| **Simulate** | Separate pure from impure (State Module, Detection, `with` pipelines) | **Highest** | 16+ State pairs → pattern completion after ~3 exposures |
| **Enumerate** | Colocate at single site (@handlers, @enforce_keys, @impl) | High | Consistent registry pattern → "look for @-list" becomes automatic |
| **Compare** | Uniform interfaces (Protocol, Behaviour, type in signatures) | Medium | 14 Detection modules, 10 provider handlers → shape becomes familiar |

| Structural Dimension | Lexical's Reduction Strategy | Frequency | Entrenchment effect |
|----------------------|------------------------------|-----------|-------------------|
| **Compose** | Flat lists, pipelines, layered macros, transparent encapsulation, closures (see deep dive) | High | Proto DSL vocabulary entrenches across 50+ protocol types |
| **Nest** | Facades, clean boundaries, thin orchestrators, encapsulation, isomorphism, framework traversal (see deep dive) | High | 16+ State pairs + 10 handler isomorphisms → pattern completion |

**Frequency matters because of entrenchment**: high-frequency patterns get fixed deeper in the reader's long-term memory (Chase & Simon 1973). The first time a developer encounters Nested State Module, they must Simulate to understand the separation. By the 4th time, they Enumerate — "ah, this is the State Module pattern." This is why Lexical's most impactful patterns are also its most frequent ones.

### The one-sentence takeaway

**Split things that would need to be simulated together, so the reader only tracks one causal chain at a time.** Nested State Module, Detection behaviour, and `with` pipelines are all doing the same thing.

---

## Cross-cutting: Pattern Completion and Isomorphism

Beyond reducing individual operations, Lexical's most powerful cognitive strategy operates at the **codebase level**: maintaining pattern consistency so that readers' brains do **pattern completion** — automatically predicting unseen code from seen parts.

In Barsalou's (2009) framework: when a situated conceptualization becomes entrenched, perceiving *part* of the pattern activates the rest as predictions. The reader's brain fills in what it hasn't seen yet.

### Structural consistency as pattern completion (horizontal isomorphism)

When multiple modules at the **same abstraction level** follow the same structural pattern, the reader understands one and predicts the rest. This is **isomorphism within a tier** — it reduces both composition cost (cheaper to enumerate) and nesting cost (no need to descend into each implementation to understand its shape).

| Pattern | Instances | Shared structure | What the reader predicts after seeing 3+ |
|---------|-----------|-----------------|----------------------------------------|
| Nested State Module | 16+ | Pure state transforms separate from OTP dispatch | "State module = pure transforms, GenServer = thin dispatch" |
| Detection behaviour | 14 modules | `use Detection` + `@impl` + `detected?/2` | "detector = walk AST → check position match" |
| Provider handlers | 10 modules | `handle/2` → `{:reply, response}` | "handler = match request → call intelligence → build response" |
| Code action handlers | 5 modules | `@behaviour Handler` + `actions/3` + `kinds/0` | "handler = filter by kind → find applicable actions" |
| Document compilers | 5 modules | `recognizes?/1` + `compile/1` + `enabled?/0` | "compiler = check language → compile document" |
| Indexer extractors | 9 modules | `extract/2` → `{:ok, entry}` / `:ignored` | "extractor = pattern match AST → produce entry" |

Martins et al. (2015) experimentally confirmed that self-similar hierarchical structures activate the **Default Mode Network**, producing compressed internal rule representations that dramatically reduce processing load. Non-self-similar structures activate the **Fronto-Parietal Control Network**, requiring independent processing of each level. Lexical's isomorphic patterns within each tier exploit the DMN path.

### Contrast: heterogeneous nesting across tiers

Lexical's LSP request pipeline crosses ~6 conceptual layers, each with a **different** structural pattern:

```
Transport (byte I/O) → Server (OTP routing) → Convert (struct mapping) →
TaskQueue (async scheduling) → Handler (domain dispatch) → CodeIntelligence (business logic)
```

The reader must build an independent model for each layer — no cross-layer prediction via isomorphism. This heterogeneous cost is inherent to the problem (transport ≠ routing ≠ conversion ≠ scheduling ≠ business logic), but Lexical mitigates it through **accurate naming at each boundary**: `StdIO`, `Convert.to_native`, `TaskQueue.add`, `handler.handle` — each name creates a high-precision prediction that prevents the reader from needing to descend.

### Naming conventions as pattern completion triggers

Lexical uses function prefixes that create predictions about behavior:

| Prefix | Reader predicts | Accuracy in Lexical |
|--------|----------------|-------------------|
| `fetch_*` | Retrieval, may fail with `{:ok, _}` / `{:error, _}` | High — consistent across `common` and `remote_control` |
| `ensure_*` | Side-effectful setup (filesystem, apps, compatibility) | High — always involves I/O |
| `to_*` / `from_*` | Shape conversion between representations | High — dominant in `protocol` |
| `do_*` | Private implementation / recursion body | High — always `defp` |
| `maybe_*` | Conditional operation, soft failure | High |
| `on_*` | Event reaction / state transition | **Medium** — see Precision Weighting below |
| `resolve_*` | Semantic resolution (aliases, modules, entities) | High — concentrated in `remote_control` |

When a developer has entrenched these conventions, seeing `fetch_` at the start of a function name activates an immediate prediction: "this retrieves data and might return an error tuple." No need to read the body — pattern completion handles it.

### The pipeline as situated conceptualization

Lexical's LSP request handling follows a consistent path:

```
incoming message → Convert.to_native → fetch_handler → Handler.handle(request, config) → response
```

After working with Lexical for a few days, this pipeline becomes an entrenched situated conceptualization. Seeing `Convert.to_native` at the start of a handler triggers pattern completion for the entire flow — the developer predicts `fetch_handler` and `Handler.handle` without reading further.

---

## Precision Weighting: When Names Create Wrong Predictions

Not all naming failures are equal. Friston (2010) showed that the brain assigns **precision** (confidence) to predictions. A precise name creates a high-precision prediction; violating it costs more than violating a vague prediction. In code: a misleading name is worse than a vague name because the reader builds a *confident wrong model* that must be dismantled.

### Consistency violations found in Lexical

Lexical's naming is highly consistent, but the few violations are instructive:

**1. `on_*` is not always a pure state transition.**

`Build.State.on_timeout` does file cleanup via `ensure_build_directory`; `Configuration.on_change` writes to `persistent_term`. A reader who entrenched "`on_*` = pure reducer" from `ProjectNode.State.on_nodeup` will hit a prediction error when they encounter these. The cost is double: discard the wrong model, then re-simulate.

**2. Detection outliers break the `use Detection` pattern.**

14 of 17 detection modules follow `use Detection` + `@impl Detection` + `detected?/2`. But `Comment` and `StructFieldValue` implement `detected?/2` without `use Detection` or `@behaviour`. `ModuleAttribute` has a 3-argument variant via `env.ex`. A reader who entrenched "all detection modules use the behaviour" will be surprised.

**3. `@impl` inconsistency in document compilers.**

`elixir.ex`, `config.ex`, `eex.ex` use `@impl true` on callbacks. `heex.ex` declares `@behaviour Compiler` but omits `@impl`. The reader who uses `@impl` to enumerate callbacks will miss HEEx's implementations.

**4. `@extractors` is not the complete set.**

`Reducer`'s default `@extractors` contains 7 modules. `Variable` and `ExUnit` extractors exist but are composed elsewhere. A reader inferring "default reducer = complete indexing" will build a wrong model.

**5. Dispatch handler inventory is smaller than the pattern suggests.**

The `Dispatch.Handler` behaviour and macro suggest many handler modules, but only `Handlers.Indexing` is a domain handler (plus `PubSub`). The infrastructure implies more scale than exists.

**6. Translatable file naming breaks file-name-to-type heuristic.**

`Candidate.Struct`'s `Translatable` implementation lives in `module_or_behaviour.ex`, not `struct.ex`. A reader using "file name = type = defimpl home" will look in the wrong file.

### Naming cost model

| Name quality | Precision | If accurate | If wrong |
|-------------|-----------|-------------|----------|
| Good name (`fetch_docs`) | High | Enumerate — near zero cost | Catastrophic — discard confident model, re-simulate |
| Vague name (`process`) | Low | Simulate — must read body | Moderate — no wrong expectations to discard |
| Misleading name (`validate` that mutates) | High | N/A | Worst case — confident wrong model, discovered late |

**Takeaway for Lexical**: the few violations above are low-severity because they are rare — the overwhelming consistency builds correct high-precision predictions. But each violation is a candidate for cleanup because its cognitive cost is disproportionate to its frequency.

---

## Productivity: Where Compose × Nest Intersect

Barsalou (1999) identifies **productivity** as the ability to generate infinite combinations from finite elements — arising from integrating elements "combinatorially and recursively." In Lexical, the Proto DSL is the clearest example:

```
Layer 0: deftype                      ← user writes ONE line (Nest: level 0)
Layer 1: Json + Inspect + Access +    ← 6 macros side by side (Compose: horizontal)
         Struct + Parse + Meta
Layer 2: each sub-macro's internals   ← independent concerns (Nest: level 2)

One layer up:
Layer 0: defrequest                   ← user writes ONE line (Nest: level 0)
Layer 1: Message.build + deftype      ← reuses deftype (Compose: horizontal)
Layer 2: Message internals + ...      ← (Nest: level 2)
```

Composition alone would produce flat lists of macros. Nesting alone would produce deep single-concern chains. Together, they produce the full expressiveness of Lexical's protocol type system: **50+ LSP types defined from a handful of composable macros at 3 abstraction levels.** One-line `deftype` declarations generate complete struct definitions with JSON encoding, inspection, access protocol, parsing, and metadata — without the user needing to understand any of those concerns.

This is what productivity means in practice: the ability to express new LSP protocol types without architectural changes.

---

## Deep Dive: Nesting and Cognitive Load

Nesting is the most expensive structural dimension because readers must **hold multiple abstraction levels in working memory simultaneously** — bounded by ~4 levels (Cowan 2001).

In code, nesting has two major manifestations:

- **Abstraction layer nesting**: module A calls module B calls module C… The reader must jump across multiple files to understand a business operation. This is the most common form of nesting in day-to-day development.
- **Code recursion**: a function calls itself; the reader must hold multiple stack frames mentally. Less frequent but extremely high cognitive cost.

Lexical's strategy: **downgrade nesting to a cheaper cognitive operation** so the reader stays at the current level, predicting the rest through naming, boundaries, or isomorphism.

---

### Part 1: Abstraction Layer Nesting

Lexical's LSP completion pipeline traverses ~15 modules from stdin to result (StdIO → Server → JsonRpc → Convert → TaskQueue → Handler → CodeIntelligence → Env → Api → erpc → RemoteControl → Completion → …return… → Translatable → Convert → Transport). If readers had to understand all layers simultaneously, the cognitive cost would be unmanageable.

#### Facade collapses entry points (Nest → Enumerate)

```elixir
# apps/remote_control/lib/lexical/remote_control.ex — 22 defdelegate calls
defdelegate compile_document(project, document), to: Api.Proxy
defdelegate complete(env), to: RemoteControl.Completion
defdelegate resolve_entity(analysis, position), to: CodeIntelligence.Entity
defdelegate broadcast(message), to: Dispatch
# ... 22 total
```

`RemoteControl` is the remote application's facade — callers need to know only one module, not the dozen internal modules behind it (Proxy, Dispatch, Completion, CodeIntelligence, etc.). Nesting depth collapses from "search N modules for the target function" to "enumerate one module."

Same pattern: `Transport` uses `defdelegate write(message), to: @implementation` to hide the transport implementation (StdIO vs NoOp) behind compile-time configuration.

#### Clean boundaries prevent descent (Nest → Naming prediction)

```elixir
# apps/remote_control/lib/lexical/remote_control/api.ex
def complete(%Project{} = project, %Env{} = env) do
  RemoteControl.call(project, RemoteControl, :complete, [env])
end

def resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
  RemoteControl.call(project, RemoteControl, :resolve_entity, [analysis, position])
end
```

`RemoteControl.Api` is the RPC boundary between manager and project nodes. Every function is a one-liner `RemoteControl.call`. When readers see `Api.complete(project, env)`, the signature `(%Project{}, %Env{})` is a complete understanding — "execute completion on the remote node with this project and environment." **No descent needed.**

The boundary's value isn't just encapsulation — it **prevents cognitive leakage**: server-side code never needs to understand the remote node's internal structure.

#### Thin orchestrator only dispatches (Nest → Linear simulate)

```elixir
# apps/server/lib/lexical/server/provider/handlers/completion.ex
def handle(%Requests.Completion{} = request, %Configuration{} = config) do
  completions =
    CodeIntelligence.Completion.complete(
      config.project,
      document_analysis(request.document, request.position),
      request.position,
      request.context || Completion.Context.new(trigger_kind: :invoked)
    )

  response = Responses.Completion.new(request.id, completions)
  {:reply, response}
end
```

The handler is a three-step linear pipeline: get analysis → call intelligence → wrap response. The reader doesn't need to descend into `CodeIntelligence.Completion` to understand what this layer does. Each step's name (`document_analysis`, `Completion.complete`, `Responses.Completion.new`) creates a sufficiently precise prediction.

#### Encapsulate complex internals behind simple API (Nest → Invisible)

```elixir
# apps/common/lib/lexical/ast.ex
# Public API: clean {:ok, path} | {:error, _}
def path_at(%Analysis{} = analysis, %Position{} = position) do
  with {:ok, ast, _} <- from(analysis) do
    path_at(ast, position)
  end
end

# Internal: the highest cognitive cost recursion in Lexical (dual branches + accumulator + || short-circuit)
defp innermost_path({form, _, args}, acc, fun) when is_atom(form) and is_list(args) do
  case fun.({form, _, args}) do
    true -> {:ok, [{form, _, args} | acc]}
    false ->
      innermost_path_args(args, [{form, _, args} | acc], fun) ||
        innermost_path_list(args, [{form, _, args} | acc], fun)
  end
end
```

Callers never touch `innermost_path/3`. Same pattern: `Env.new/3` hides the combination of 13+ Detection modules, `CodeIntelligence.Completion.complete/4` hides the full filtering/translation/building pipeline.

General principle: **complexity can exist, but must be encapsulated behind a public API rather than leaking to callers.**

#### Isomorphic layers (Nest → Compare)

When multiple modules at the **same tier** follow the same structural pattern, understanding one predicts the rest — downgrading nesting from simulation to comparison. Martins et al. (2015) showed self-similar structures activate the **Default Mode Network** (compressed rule representations), while non-self-similar structures activate the costly **Fronto-Parietal Control Network**.

Lexical's clearest isomorphism: all 10 LSP handler modules follow `handle/2` → call intelligence → `{:reply, response}`. After reading `Handlers.Completion`, readers predict `Handlers.Hover`, `Handlers.GoToDefinition`, etc. without descending — **parameter substitution on a known pattern**, not fresh simulation.

This extends to other tiers: code action handlers (5 with `actions/3` + `kinds/0`), document compilers (5 with `recognizes?/1` + `compile/1` + `enabled?/0`), indexer extractors (9 with `extract/2`).

#### Contrast: heterogeneous nesting across tiers

Lexical's LSP request pipeline crosses ~6 conceptual layers, each with a **different** structural pattern:

```
Transport (byte I/O) → Server (OTP routing) → Convert (struct mapping) →
TaskQueue (async scheduling) → Handler (domain dispatch) → CodeIntelligence (business logic)
```

The reader must build an independent model for each layer — no cross-layer prediction via isomorphism. This heterogeneous cost is inherent (transport ≠ routing ≠ conversion ≠ scheduling ≠ business logic), but Lexical mitigates it through **accurate naming at each boundary**: `StdIO`, `Convert.to_native`, `TaskQueue.add`, `handler.handle` — each name creates a high-precision prediction that prevents descent.

---

### Part 2: Code Recursion — A Special Form of Nesting

Code recursion is nesting where a function calls itself; readers must hold multiple stack frames mentally. Lexical's strategy: downgrade recursion so readers **don't think recursively about recursive code**.

#### Framework absorbs traversal (Nest → Single-step simulate)

The most frequently used recursion pattern. The reader's mental model is "do X for each node," not "recursively traverse a tree."

```elixir
# apps/common/lib/lexical/ast/detection/string.ex
defp detect_string(paths, %Position{} = position) do
  {_, detected?} =
    Macro.postwalk(paths, false, fn
      ast, true  -> {ast, true}                     # already found, short-circuit
      ast, false -> {ast, do_detect(ast, position)}  # check current node
    end)
  detected?
end
```

The callback processes **one node**. `Macro.postwalk` handles all traversal — **severing the simulation chain** by splitting "how to traverse" from "what to do at each step."

| Framework | Reader's mental model | Usage |
|-----------|----------------------|-------|
| `Macro.prewalk` | "Do X for each node top-down" | analysis.ex, variable.ex, quoted.ex, ecto_schema.ex, function_definition.ex, wal.ex |
| `Macro.postwalk` | "Do X for each node bottom-up" | string.ex, namespace/configs.ex |
| `Macro.traverse` | "Do X on enter, Y on leave" | analysis.ex, error.ex |
| `Zipper.traverse_while` | "Do X for each node in range" | ast.ex `traverse_in/4` |
| `Zipper.find` | "Find first node matching P" | remove_unused_alias.ex, entity.ex, ast.ex |
| Protocol dispatch | "Convert this thing" | convertible.ex |

#### Multi-clause mirrors data shape (Nest → Enumerate)

```elixir
# apps/common/lib/future/code/typespec.ex
defp collect_vars({:type, _anno, _kind, args}) when is_list(args) do
  Enum.flat_map(args, &collect_vars/1)        # type with children → expand
end
defp collect_vars({:paren_type, _anno, [type]}), do: collect_vars(type)  # parentheses → unwrap
defp collect_vars({:var, _anno, var}), do: [erl_to_ex_var(var)]          # variable → collect
defp collect_vars(_), do: []                                             # anything else → ignore
```

The reader's mental model is **"enumerate four cases"**, not "recursively walk a type tree." Structural recursion — the clause structure mirrors the data structure. `Enum.flat_map` presents recursion as **iteration**.

#### Tail recursion disguised as loop (Nest → Loop simulate)

```elixir
# apps/remote_control/lib/lexical/remote_control/search/indexer/source/reducer.ex
defp maybe_pop_block(%__MODULE__{} = reducer) do
  if block_ended?(reducer) do
    reducer |> pop_block() |> maybe_pop_block()
  else
    reducer
  end
end
```

The reader's mental model is a **while loop**: "keep popping blocks until no more have ended." No multiple stack frames — just one `reducer` evolving over time.

#### Protocol dispatch hides nesting (Nest → Invisible)

```elixir
Convertible.to_native(some_nested_struct, doc)
# Any impl auto-recurses: Map.from_struct → call to_native on each field
# List/Map impls auto-recurse: call to_native on each element/value
```

The caller **doesn't know nesting exists**. Multi-level traversal is fully absorbed by protocol polymorphic dispatch.

#### `update_in` with dynamic path (Nest → Declarative)

```elixir
hierarchy = update_in(reducer.block_hierarchy, id_path, fn current ->
  Map.put(current, block.id, %{})
end)
```

Nested map update is inherently recursive, but `update_in` makes it declarative: "at this path, do this operation."

---

### Anti-patterns: When nesting stays expensive

**Mutual recursion** — `rebuild_structure` and `map_block_type` in symbol tree building call each other; the reader must track a **call graph**, not a single function.

**Mixed fold + recursion** — `do_collect_parents` calls itself inside `Enum.reduce`: iteration and recursion control flows interleave, harder than either alone.

### Nesting reduction summary

| | Strategy | Nesting downgraded to | Reader's mental model | Frequency |
|-|----------|----------------------|----------------------|-----------|
| **Abstraction layers** | Facade / defdelegate | Enumerate | "Find all entries in one module" | High |
| | Clean boundaries | Naming prediction | "Api.complete = RPC call, no descent" | High |
| | Thin orchestrator | Linear simulate | "get → call → wrap, three steps" | High |
| | Encapsulate internals | Invisible | "Call path_at, ignore internal complexity" | High |
| | Isomorphic layers | Compare | "Same shape as the handler I already read" | High |
| **Code recursion** | Framework absorbs traversal | Single-step simulate | "Do X for each node" | Highest |
| | Multi-clause mirrors data | Enumerate | "These N cases do what" | High |
| | Tail recursion | Loop simulate | "Keep doing until done" | Medium |
| | Protocol dispatch | Invisible | "Convert this thing" | Medium |
| | `update_in` / path-based | Declarative | "At this path, do this" | Low |

### The one-sentence takeaway on nesting

**Good nesting is not cleverer abstraction — it's nesting that lets readers stay at the current level.** Abstraction layer nesting is controlled through facades, boundaries, and isomorphism; code recursion is dissolved through framework absorption and structural mapping. The shared principle: the reader doesn't need to descend to build a correct mental model.

---

## Deep Dive: Composition and Cognitive Load

Composition is a structural dimension. Its cost comes from three steps:
1. **Understand each part** (simulate each part)
2. **Understand the connections** (compare interfaces)
3. **Understand the emergent whole** (simulate the combined behavior)

Step 3 is the killer. If you must **understand all parts simultaneously** to understand the whole, cognitive cost is multiplicative (element interactivity in Sweller's terms). Lexical's strategy: **let readers understand each part independently, then understand the whole through cheap operations** (enumerate, compare, linear simulate).

### Technique 1: Flat composition (Compose → Enumerate)

The simplest composition: lay parts in a flat list, merge results with `flat_map`. Parts have zero coupling.

```elixir
# apps/remote_control/lib/lexical/remote_control/code_action.ex
@handlers [
  Handlers.ReplaceRemoteFunction,
  Handlers.ReplaceWithUnderscore,
  Handlers.OrganizeAliases,
  Handlers.AddAlias,
  Handlers.RemoveUnusedAlias
]

def for_range(doc, range, diagnostics, kinds) do
  Enum.flat_map(@handlers, fn handler ->
    if applies?(kinds, handler), do: handler.actions(doc, range, diagnostics), else: []
  end)
end
```

To understand the whole: **enumerate the 5 modules in the list**. Each works independently, results are simply merged. You don't need to understand handler A to understand handler B.

The same pattern appears in compiler selection:

```elixir
# apps/remote_control/lib/lexical/remote_control/build/document.ex
@compilers [Compilers.Config, Compilers.Elixir, Compilers.EEx, Compilers.HEEx, Compilers.NoOp]

def compile(document) do
  compiler = Enum.find(@compilers, & &1.recognizes?(document))
  compiler.compile(document)
end
```

**Cognitive formula**: cost of understanding the whole = Σ(cost of each part) + enumeration cost, NOT Π(cost of each part).

**Variations on flat composition:**

**Map-based registry** — flat composition over a map instead of a list:

```elixir
# apps/common/lib/lexical/ast/env.ex
@detectors %{
  alias: Detection.Alias,
  import: Detection.Import,
  pipe: Detection.Pipe,
  # ... 12+ context → detector mappings
}
```

Unlike `@handlers` (iterate all, merge results), `@detectors` evaluates **every** detector up front and builds a context map. The reader still enumerates, but the mental model is "registry lookup" rather than "fan-out and merge."

**Stateful sequential pipeline** — ordered application with shared state:

```elixir
# apps/remote_control/lib/lexical/remote_control/search/indexer/source/reducer.ex
@extractors [
  Extractors.FunctionDefinition,
  Extractors.Module,
  Extractors.ModuleAttribute,
  # ...
]

def apply_extractors(%__MODULE__{} = reducer, elem) do
  Enum.reduce(@extractors, {reducer, elem}, fn extractor, {reducer, elem} ->
    # each extractor can modify reducer state
  end)
end
```

Unlike independent `flat_map`, extractors run in order and share reducer state. The reader still enumerates the list, but must understand that **order and shared state matter** — slightly higher cognitive load than pure flat composition.

### Technique 2: Pipeline composition (Compose → Linear simulate)

Parts are sequenced. Each step's output feeds the next step's input. The reader traces a linear data flow.

```elixir
# apps/remote_control/lib/lexical/remote_control/api/proxy/buffering_state.ex
def flush(%__MODULE__{} = state) do
  {messages, commands} =
    state.buffer
    |> Enum.reverse()                          # Step 1: reverse
    |> Enum.split_with(fn value ->             # Step 2: partition
      match?(mfa(module: Dispatch, function: :broadcast), value)
    end)

  {project_compile, document_compiles, reindex} = collapse_commands(commands)

  all_commands
  |> Enum.concat(collapse_messages(...))       # Step 3: merge
  |> Enum.filter(&match?(mfa(), &1))           # Step 4: filter
  |> Enum.sort_by(fn mfa(seq: seq) -> seq end) # Step 5: sort
end
```

The reader's mental model is a **straight line**: data in → transform1 → transform2 → ... → data out. No branching to maintain in working memory.

**Flat vs Pipeline**: flat parts work **in parallel** (independent, merged) → enumerate. Pipeline parts work **in series** (sequential, chained) → linear simulate. Both avoid "understand all parts simultaneously."

### Technique 3: Layered composition (Compose → Layer-by-layer simulate)

The most sophisticated composition technique in Lexical, concentrated in the Proto DSL.

```
What the user sees:
  deftype [name: string(), range: optional(range_type())]

What actually expands:
  Layer 0: deftype                      ← user writes this
  Layer 1: Json + Inspect + Access + Struct + Parse + Meta  ← deftype composes these
  Layer 2: each sub-macro's internals   ← sub-macros work independently
```

```elixir
# apps/proto/lib/lexical/proto/type.ex
defmacro deftype(types) do
  quote location: :keep do
    unquote(Json.build(caller_module))       # concern 1
    unquote(Inspect.build(caller_module))    # concern 2
    unquote(Access.build())                  # concern 3
    unquote(Struct.build(types, __CALLER__)) # concern 4
    unquote(Parse.build(types))              # concern 5
    unquote(Meta.build(types))               # concern 6
  end
end
```

One layer up, `defrequest` composes `Message.build` (which reuses deftype's sub-macros):

```elixir
# apps/proto/lib/lexical/proto/request.ex
defp do_defrequest(method, types, caller) do
  quote location: :keep do
    defmodule LSP do
      unquote(Message.build({:request, :lsp}, method, lsp_types, ...))
    end
    unquote(Message.build({:request, :elixir}, method, elixir_types, ...))
  end
end
```

**Cognitive effect**: the reader at **any layer** doesn't need to understand other layers.
- User writing `deftype`: only needs "declare fields and types"
- Maintainer reading `deftype` macro: only needs "6 sub-macros, each does what" (enumerate)
- Maintainer reading `Json.build`: only needs "generate Jason.Encoder implementation"

Each layer is an **abstraction barrier** that prevents cognitive load from leaking upward. This is the core value of composition in functional programming.

**Contrast with the anti-pattern**: if `deftype` inlined all generation logic in one macro, the reader would need to simultaneously understand JSON encoding, Inspect implementation, Access protocol, struct definition, parsing logic, and metadata — 6 concerns interleaved.

### Technique 4: Transparent composition (Compose → Invisible)

The composition exists, but the caller doesn't know about it.

```elixir
# apps/remote_control/lib/lexical/remote_control/api/proxy/draining_state.ex
defstruct [:proxying_state, :buffering_state]

def new(%BufferingState{} = bs, %ProxyingState{} = ps) do
  %__MODULE__{buffering_state: bs, proxying_state: ps}
end

# Delegates to internal components — caller doesn't need to know
def drained?(%__MODULE__{} = state) do
  ProxyingState.empty?(state.proxying_state)
end

def add_mfa(%__MODULE__{} = state, mfa) do
  %__MODULE__{state | buffering_state: BufferingState.add_mfa(state.buffering_state, mfa)}
end
```

When Proxy's `gen_statem` calls `DrainingState.add_mfa(state, mfa)`, it **doesn't know** BufferingState is doing the work underneath. The composition is encapsulated behind DrainingState's interface.

The same pattern appears in:
- Analysis (composing AST + Document + Scopes + Comments into one struct)
- `RemoteControl` facade (`defdelegate` to Proxy, CodeAction, Completion, etc.)
- `Transport` (`defdelegate write(message), to: @implementation` where `@implementation` is compile-time configured)

**Cognitive principle**: same as "protocol dispatch hides nesting" — **if composition is invisible to the caller, its cognitive cost is zero**.

### Technique 5: Closure composition (Compose → Single concept)

Pack a multi-step operation into a closure and hand it to the caller as a single "capability."

```elixir
# apps/remote_control/lib/lexical/remote_control/progress.ex
def with_percent_progress(label, max, func) when is_function(func, 1) do
  {report_progress, on_complete} = begin_percent(label, max)

  try do
    func.(report_progress)  # passes "report progress" capability as argument
  after
    on_complete.()           # cleanup encapsulated in closure
  end
end

defp begin_percent(label, max) do
  report = fn delta -> broadcast(percent_progress(label: label, ...)) end
  complete = fn -> broadcast(project_progress(label: label, stage: :complete)) end
  {report, complete}
end
```

The caller's view:

```elixir
with_percent_progress("Indexing", file_count, fn report ->
  Enum.each(files, fn file ->
    index(file)
    report.(1)  # just call a function
  end)
end)
```

The caller doesn't need to understand the progress system's internals (broadcasting, events, label capture). They receive a **single concept**: "calling `report.(1)` reports progress."

**Cognitive principle**: the closure packages "combined behavior" into a callable object. No enumeration of parts, no comparison of interfaces — just "what does calling this function do?"

### Composition reduction summary

| Strategy | Composition downgraded to | Reader's mental model | Use case |
|----------|--------------------------|----------------------|----------|
| Flat composition | Enumerate | "N independent parts, merged results" | @handlers, @compilers, @detectors |
| Stateful pipeline | Linear simulate (with shared state) | "Extractors run in order, building up results" | @extractors + Reducer |
| Pipeline composition | Linear simulate | "Data flows through a series of transforms" | `with` chains, `\|>` pipes, Enum chains |
| Layered composition | Layer-by-layer simulate | "This layer does X, don't care how layers below work" | Proto DSL, macro systems |
| Transparent composition | Invisible | "Call this module" (unaware of internal composition) | DrainingState, Analysis, Transport, RemoteControl facade |
| Closure composition | Single concept | "Call this function" | Progress, resource management, formatter wrapping |

### The one-sentence takeaway on composition

**Good composition lets you understand the whole without understanding all parts simultaneously.** The best composed code is code where the reader doesn't even know there are multiple parts.
