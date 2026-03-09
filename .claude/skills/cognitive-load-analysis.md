# Cognitive Load Analysis of Lexical Patterns

How Lexical's codebase patterns reduce cognitive load, analyzed through five fundamental cognitive operations (from Barsalou's Perceptual Symbol Systems framework).

## The Five Cognitive Operations

Ordered by cognitive cost, low to high:

| Order | Operation | What the reader does |
|-------|-----------|---------------------|
| First | **Enumerate** | Scan and list visible elements |
| First | **Compare** | Find similarities/differences between two things |
| First | **Simulate** | Mentally execute code, track state changes, predict outcomes |
| Second | **Compose** | Assemble parts into a whole |
| Second | **Recurse** | Apply a pattern at multiple levels of abstraction |

First-order operations are cheap. Second-order operations are expensive. **Simulate** is the most expensive first-order operation — it requires maintaining mental state, tracking control flow, and predicting side effects simultaneously.

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

This is Lexical's **most frequently used technique**. ProjectNode, Proxy's three state modules (BufferingState/ProxyingState/DrainingState), and PubSub.State all follow this pattern.

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
def snipe(%Setup{} = setup) do
  with {:ok, prepared} <- Transaction.prepare(setup),
       {:ok, result}   <- Submission.execute(prepared, setup) do
    {:ok, result}
  end
end
```

The reader's simulation path is **linear**: step1 → step2 → done. No need to maintain a branch tree in working memory. Each step's name (`Transaction.prepare`, `Submission.execute`) tells **what** it does — no need to expand the function body to simulate **how**.

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
def prepare(%Setup{} = setup) do ...
```

The reader doesn't need to enter the function body and simulate data flow to confirm input type. At the signature: expected Setup, receiving Setup? Done. One **comparison** at the call site, zero **simulation** required.

---

## Higher-Order Operations: Compose and Recurse

Lexical handles second-order operations more subtly, and uses them less frequently:

### Compose — Proto DSL's layered macro design

```
deftype = Json.build + Inspect.build + Access.build + Struct.build + Parse.build + Meta.build
defrequest = deftype + Message.build + Jason.Encoder
```

Each layer only needs to understand its own input/output, not the other layers' implementations. The composition cost is **encapsulated** inside macros — the user sees a single `deftype [name: string(), ...]`.

### Recurse — Convertible protocol's automatic recursion

```elixir
# Any fallback recursively converts struct fields
def to_native(%_struct{} = struct, context_document) do
  struct |> Map.from_struct() |> Helpers.apply(&Convertible.to_native/2, context_document)
end
```

The reader doesn't need to think recursively — the protocol framework recurses for them. Recursive cognitive load is absorbed by the framework, leaving the reader with a flat mental model.

---

## Summary

| Cognitive Operation | Lexical's Reduction Strategy | Frequency |
|--------------------|------------------------------|-----------|
| **Simulate** | Separate pure from impure (State Module, Detection, `with` pipelines) | **Highest** |
| **Enumerate** | Colocate at single site (@handlers, @enforce_keys, @impl) | High |
| **Compare** | Uniform interfaces (Protocol, Behaviour, type in signatures) | Medium |
| **Compose** | Encapsulate in macros; users see declarative API (Proto DSL) | Low |
| **Recurse** | Framework recurses automatically; users think flat (Convertible Any) | Low |

### The one-sentence takeaway

**Split things that would need to be simulated together, so the reader only tracks one causal chain at a time.** Nested State Module, Detection behaviour, and `with` pipelines are all doing the same thing.

---

## Deep Dive: Recursion and Cognitive Load

Recursion is the most expensive cognitive operation because readers must **hold multiple stack frames in working memory simultaneously** — simulating "a simulation," a second-order operation. Lexical's strategy: **downgrade recursion to a cheaper cognitive operation** so the reader never thinks recursively.

### Technique 1: Framework absorbs traversal (Recurse → Single-step simulate)

The most frequently used recursion pattern in Lexical. The reader's mental model is "do X for each node," not "recursively traverse a tree."

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

The callback processes **one node**. `Macro.postwalk` handles all traversal logic. This is the same principle as Nested State Module — **sever the simulation chain** by splitting "how to traverse" from "what to do at each step."

| Framework | Reader's mental model | Usage |
|-----------|----------------------|-------|
| `Macro.prewalk` | "Do X for each node top-down" | analysis.ex, variable.ex, quoted.ex |
| `Macro.postwalk` | "Do X for each node bottom-up" | string.ex |
| `Macro.traverse` | "Do X on enter, Y on leave" | analysis.ex, error.ex |
| `Zipper.traverse` | "Do X for each node in range" | ast.ex `traverse_in/4` |
| `Zipper.find` | "Find first node matching P" | remove_unused_alias.ex |
| Protocol dispatch | "Convert this thing" | convertible.ex |

### Technique 2: Multi-clause mirrors data shape (Recurse → Enumerate)

```elixir
# apps/common/lib/future/code/typespec.ex
defp collect_vars({:type, _anno, _kind, args}) when is_list(args) do
  Enum.flat_map(args, &collect_vars/1)        # type with children → expand
end

defp collect_vars({:paren_type, _anno, [type]}) do
  collect_vars(type)                           # parentheses → unwrap
end

defp collect_vars({:var, _anno, var}) do
  [erl_to_ex_var(var)]                         # variable → collect (base case)
end

defp collect_vars(_) do
  []                                           # anything else → ignore (base case)
end
```

The reader's mental model is not "recursively walk a type tree" but **"enumerate four cases"**:
1. Type with children → expand
2. Parentheses → unwrap
3. Variable → collect
4. Other → ignore

Each clause is independently readable. This is **structural recursion** — the function's clause structure mirrors the data structure, one-to-one. The `Enum.flat_map(args, &collect_vars/1)` expression is especially important: it presents "recurse on each element" as "flat_map over a list" — the reader sees **iteration**, not recursion.

### Technique 3: Tail recursion disguised as loop (Recurse → Loop simulate)

```elixir
# apps/remote_control/lib/lexical/remote_control/search/indexer/source/reducer.ex
defp maybe_pop_block(%__MODULE__{} = reducer) do
  if block_ended?(reducer) do
    reducer
    |> pop_block()
    |> maybe_pop_block()   # tail recursion
  else
    reducer
  end
end
```

The reader's mental model is a **while loop**: "keep popping blocks until no more blocks have ended." No need to hold multiple stack frames — there's only one `reducer` evolving over time.

Key detail: **condition, transformation, and recursion** are split into three independent concerns:
- `block_ended?` — pure predicate, no state change
- `pop_block` — pure transformation, no branching or recursion
- `maybe_pop_block` — skeleton: check → transform → recurse

### Technique 4: Protocol dispatch hides recursion (Recurse → Invisible)

```elixir
# What the caller writes:
Convertible.to_native(some_nested_struct, doc)

# What actually happens:
# 1. Any impl: Map.from_struct → call to_native on each field
# 2. List impl: call to_native on each element
# 3. Map impl: call to_native on each value
# 4. Specific impl: do type-specific conversion
```

The caller **doesn't know recursion exists**. They see one function call returning one result. The recursion is fully absorbed by protocol polymorphic dispatch. This is the ultimate form of cognitive cost reduction: **eliminate the reader's awareness that recursion is happening**.

### Technique 5: `update_in` with dynamic path (Recurse → Declarative)

```elixir
# reducer.ex
hierarchy =
  update_in(reducer.block_hierarchy, id_path, fn current ->
    Map.put(current, block.id, %{})
  end)
```

Updating a nested map is inherently recursive (descend layer by layer along the path), but `update_in` makes it declarative: "at this path, do this operation." The reader doesn't need to think "open layer 1, open layer 2, modify, close layer 2, close layer 1."

### Anti-pattern: When recursion stays recursive

For contrast, one of Lexical's few places requiring genuine recursive thinking:

```elixir
# apps/common/lib/lexical/ast.ex  innermost_path/3
defp innermost_path({form, _, args}, acc, fun) when is_atom(form) and is_list(args) do
  case fun.({form, _, args}) do
    true -> {:ok, [{form, _, args} | acc]}
    false ->
      innermost_path_args(args, [{form, _, args} | acc], fun) ||
        innermost_path_list(args, [{form, _, args} | acc], fun)
  end
end
```

This requires tracking: accumulator mutation, two recursive branches (args and list), `||` short-circuit semantics, and how the path builds inside-out. It's the highest cognitive cost recursion in Lexical.

But note: Lexical **encapsulates it behind `path_at/2`**, so callers never touch this recursion directly.

### Recursion reduction summary

| Strategy | Recursion downgraded to | Reader's mental model | Frequency |
|----------|------------------------|----------------------|-----------|
| Framework absorbs traversal | Single-step simulate | "Do X for each node" | **Highest** |
| Multi-clause mirrors data | Enumerate | "These N cases do what" | High |
| Tail recursion | Loop simulate | "Keep doing until done" | Medium |
| Protocol dispatch | Invisible | "Convert this thing" | Medium |
| `update_in` / path-based | Declarative | "At this path, do this" | Low |

### The one-sentence takeaway on recursion

**Good recursion is not cleverer recursion — it's recursion that the reader doesn't need to think about recursively.** The best recursive code is code where the reader doesn't even know it's recursing.
