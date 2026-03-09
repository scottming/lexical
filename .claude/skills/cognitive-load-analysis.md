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
