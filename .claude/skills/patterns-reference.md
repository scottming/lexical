# Lexical Codebase Pattern Reference

A comprehensive catalog of elegant patterns from the Lexical LSP codebase, organized by architectural theme. Use this as inspiration when designing similar systems.

---

## 1. Nested State Module

Separate all state logic from OTP callbacks. The State module is a pure functional core; the GenServer is a thin dispatcher.

**Reference**: `apps/remote_control/lib/lexical/remote_control/project_node.ex`

```elixir
defmodule ProjectNode do
  defmodule State do
    defstruct [:project, :port, :cookie, :stopped_by, :stop_timeout, :started_by, :status]

    def new(%Project{} = project) do
      %__MODULE__{project: project, cookie: Node.get_cookie(), status: :initializing}
    end

    # Pure: old state in, new state out
    def start(%__MODULE__{} = state, paths, from) do
      port = RemoteControl.Port.open_elixir(state.project, args: build_args(state, paths))
      %{state | port: port, started_by: from}
    end

    def on_nodeup(%__MODULE__{} = state, node_name) do
      if node_name == Project.node_name(state.project) do
        GenServer.reply(state.started_by, :ok)
        %{state | status: :started}
      else
        state
      end
    end

    def on_nodedown(%__MODULE__{} = state, node_name) do
      if node_name == Project.node_name(state.project) do
        maybe_reply_to_stopper(state)
        {:shutdown, %{state | status: :stopped}}
      else
        :continue
      end
    end
  end

  use GenServer

  # GenServer just dispatches to State functions
  @impl true
  def handle_call({:start, paths}, from, %State{} = state) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)
    Process.send_after(self(), :maybe_start_timeout, @start_timeout)
    state = State.start(state, paths, from)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node, _}, %State{} = state) do
    state = State.on_nodeup(state, node)
    {:noreply, state}
  end
end
```

**Why it works**: State module functions are pure (testable without GenServer), transitions are explicit, and the GenServer reads as a flat dispatch table.

### Composable State Modules (Advanced)

When a process has multiple phases, use separate state structs that compose.

**Reference**: `apps/remote_control/lib/lexical/remote_control/api/proxy/`

```elixir
# Phase 1: buffering commands during startup
defmodule BufferingState do
  defstruct initiator_pid: nil, buffer: []

  def new(initiator_pid), do: %__MODULE__{initiator_pid: initiator_pid}

  def add_mfa(%__MODULE__{} = state, mfa() = mfa_record) do
    %__MODULE__{state | buffer: [mfa_record | state.buffer]}
  end
end

# Phase 2: proxying commands to remote node
defmodule ProxyingState do
  defstruct refs_to_from: %{}

  def apply_mfa(%__MODULE__{} = state, from, mfa(module: m, function: f, arguments: a)) do
    task = Task.async(m, f, a)
    %__MODULE__{state | refs_to_from: Map.put(state.refs_to_from, task.ref, from)}
  end

  def consume_reply(%__MODULE__{} = state, ref) do
    %__MODULE__{state | refs_to_from: Map.delete(state.refs_to_from, ref)}
  end

  def empty?(%__MODULE__{} = state), do: Enum.empty?(state.refs_to_from)
end

# Transition phase: draining old requests while buffering new ones
defmodule DrainingState do
  defstruct [:proxying_state, :buffering_state]

  def new(%BufferingState{} = bs, %ProxyingState{} = ps) do
    %__MODULE__{buffering_state: bs, proxying_state: ps}
  end

  def drained?(%__MODULE__{} = state), do: ProxyingState.empty?(state.proxying_state)

  def consume_reply(%__MODULE__{} = state, ref) do
    %__MODULE__{state | proxying_state: ProxyingState.consume_reply(state.proxying_state, ref)}
  end
end
```

The `gen_statem` dispatches to the current phase's state module:

```elixir
# Proxy transitions between states
def proxying({:call, from}, {:start_buffering, caller}, %ProxyingState{} = state) do
  buffering_state = BufferingState.new(caller)

  if ProxyingState.empty?(state) do
    {:next_state, :buffering, buffering_state, {:reply, from, :ok}}
  else
    draining_state = DrainingState.new(buffering_state, state)
    {:next_state, :draining, draining_state, {:reply, from, :ok}}
  end
end
```

---

## 2. @handlers Registration

Explicit handler registry in a module attribute. Compile-time safe, no reflection, excellent discoverability.

**Reference**: `apps/remote_control/lib/lexical/remote_control/code_action.ex`

```elixir
@handlers [
  Handlers.ReplaceRemoteFunction,
  Handlers.ReplaceWithUnderscore,
  Handlers.OrganizeAliases,
  Handlers.AddAlias,
  Handlers.RemoveUnusedAlias
]

def for_range(%Document{} = doc, %Range{} = range, diagnostics, kinds) do
  Enum.flat_map(@handlers, fn handler ->
    if applies?(kinds, handler) do
      handler.actions(doc, range, diagnostics)
    else
      []
    end
  end)
end

defp applies?(:all, _handler_module), do: true
defp applies?(kinds, handler_module), do: kinds -- handler_module.kinds() != kinds
```

Each handler implements a simple behaviour:

```elixir
defmodule CodeAction.Handler do
  @callback actions(Document.t(), Range.t(), [Diagnostic.t()]) :: [CodeAction.t()]
  @callback kinds() :: [CodeAction.code_action_kind()]
end

# Implementation
defmodule Handlers.AddAlias do
  @behaviour CodeAction.Handler

  @impl CodeAction.Handler
  def actions(%Document{} = doc, %Range{} = range, _diagnostics) do
    with {:ok, _doc, %Analysis{valid?: true} = analysis} <-
           Document.Store.fetch(doc.uri, :analysis),
         {:ok, resolved, _} <- Entity.resolve(analysis, range.start),
         {:ok, unaliased_module} <- fetch_unaliased_module(analysis, range.start, resolved) do
      unaliased_module
      |> possible_aliases()
      |> filter_by_resolution(resolved)
      |> Stream.map(&build_code_action(analysis, range, current_aliases, &1))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @impl CodeAction.Handler
  def kinds, do: [:quick_fix]
end
```

**Why it works**: Adding a handler = add module to list + implement behaviour. No dynamic lookup, no runtime module scanning, compilation fails if handler doesn't exist.

---

## 3. Behaviour + Macro Synergy (Detection)

Define a behaviour for the contract, provide a `__using__` macro that imports shared helpers and registers the behaviour. Implementers get a batteries-included experience.

**Reference**: `apps/common/lib/lexical/ast/detection.ex`

```elixir
defmodule Lexical.Ast.Detection do
  @callback detected?(Analysis.t(), Position.t()) :: boolean()

  defmacro __using__(_) do
    quote do
      @behaviour unquote(__MODULE__)
      import unquote(__MODULE__)  # imports helper functions below
    end
  end

  # Shared helpers available to all detection modules
  def ancestor_is_def?(%Analysis{} = analysis, %Position{} = position) do
    analysis
    |> Ast.cursor_path(position)
    |> Enum.any?(fn
      {:def, _, _} -> true
      {:defp, _, _} -> true
      _ -> false
    end)
  end

  def ancestor_is_spec?(analysis, position), do: ancestor_is_attribute?(analysis, position, :spec)
  def ancestor_is_type?(analysis, position), do: ancestor_is_attribute?(analysis, position, @type_keys)

  def fetch_range(ast, start_offset \\ 0, end_offset \\ 0) do
    # Extracts source range from AST metadata
  end
end
```

Implementations are minimal — they only express the unique detection logic:

```elixir
# Simple: one-liner delegating to a helper
defmodule Detection.Spec do
  use Detection

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    ancestor_is_spec?(analysis, position)
  end
end

# Complex: custom token stream analysis
defmodule Detection.Alias do
  use Detection

  @impl Detection
  def detected?(%Analysis{} = analysis, %Position{} = position) do
    analysis.document
    |> Tokens.prefix_stream(position)
    |> Stream.with_index()
    |> Enum.reduce_while(false, fn
      {{:identifier, ~c"alias", _}, 0}, _ -> {:halt, false}
      {{:identifier, ~c"alias", _}, _index}, _ -> {:halt, true}
      {{:curly, :"}", _}, _index}, _ -> {:halt, false}
      _, _ -> {:cont, false}
    end)
  end
end
```

**Why it works**: The behaviour enforces the contract, the macro provides helpers, and each implementation is independently testable. A detector can be as simple or complex as needed.

---

## 4. Event Handler with Generated Dispatch (Dispatch.Handler)

Declare which events you care about in `use`, get pattern-matched `handle_event/2` clauses generated for you, and only implement `on_event/2` for business logic.

**Reference**: `apps/remote_control/lib/lexical/remote_control/dispatch/handler.ex`

```elixir
defmacro __using__(event_types) do
  event_types = List.wrap(event_types)

  handler_bodies =
    if Enum.member?(event_types, :all) do
      [all_handler()]
    else
      handler_bodies(event_types)
    end

  quote do
    @behaviour unquote(__MODULE__)

    def init(arg), do: {:ok, arg}

    # Generated: one handle_event clause per declared event type
    unquote_splicing(handler_bodies)

    # Catch-all: ignore undeclared events
    def handle_event(_event, state), do: {:ok, state}

    defoverridable init: 1, on: 2
  end
end

# Each declared event type gets a guard-based dispatch clause
defp event_handler(event_name) do
  quote do
    def handle_event(event, state)
        when is_tuple(event) and elem(event, 0) == unquote(event_name) do
      on_event(event, state)
    end
  end
end
```

Usage — handler only writes `on_event/2`:

```elixir
defmodule Handlers.Indexing do
  use Dispatch.Handler, [file_compile_requested(), filesystem_event()]

  def on_event(file_compile_requested(uri: uri), state) do
    reindex(uri)
    {:ok, state}
  end

  def on_event(filesystem_event(uri: uri, event_type: :deleted), state) do
    delete_path(uri)
    {:ok, state}
  end

  def on_event(filesystem_event(), state) do
    {:ok, state}
  end
end
```

**Why it works**: Eliminates boilerplate `handle_event` routing. The `use` declaration is a readable manifest of handled events. Unknown events are silently ignored via the generated catch-all.

---

## 5. Protocol with @fallback_to_any (Translatable / Convertible)

Use Elixir protocols for open polymorphism. `@fallback_to_any true` provides safe defaults for unimplemented types.

### 5a. Translatable — completion candidate translation

**Reference**: `apps/server/lib/lexical/server/code_intelligence/completion/translatable.ex`

```elixir
defprotocol Translatable do
  @type translated :: [Completion.Item.t()] | Completion.Item.t() | :skip

  @fallback_to_any true
  @spec translate(t, Builder.t(), Env.t()) :: translated
  def translate(item, builder, env)
end

# Unknown types safely return :skip
defimpl Translatable, for: Any do
  def translate(_any, _builder, _environment), do: :skip
end

# Each candidate type has its own translation
defimpl Translatable, for: Candidate.Function do
  def translate(function, _builder, %Env{} = env) do
    if Env.in_context?(env, :function_capture) do
      Translations.Callable.capture_completions(function, env)
    else
      Translations.Callable.completion(function, env)
    end
  end
end

defimpl Translatable, for: Candidate.Macro do
  def translate(macro, builder, %Env{} = env) do
    Translations.Macro.translate(macro, builder, env)
  end
end
```

### 5b. Convertible — bidirectional LSP/Native conversion

**Reference**: `projects/lexical_shared/lib/lexical/convertible.ex`

```elixir
defprotocol Lexical.Convertible do
  @fallback_to_any true

  @spec to_native(t, Document.Container.maybe_context_document()) :: {:ok, native()} | {:error, term}
  def to_native(t, context_document)

  @spec to_lsp(t) :: {:ok, lsp()} | {:error, term}
  def to_lsp(t)
end

# Fallback: recursively convert struct fields
defimpl Lexical.Convertible, for: Any do
  def to_native(%_struct_module{} = struct, context_document) do
    context_document = Document.Container.context_document(struct, context_document)

    result =
      struct
      |> Map.from_struct()
      |> Helpers.apply(&Convertible.to_native/2, context_document)

    case result do
      l when is_list(l) -> {:ok, Map.merge(struct, Map.new(l))}
      error -> error
    end
  end

  def to_native(any, _context_document), do: {:ok, any}
end

# Specific types override when needed
defimpl Lexical.Convertible, for: Lexical.Protocol.Types.Range do
  def to_native(%Types.Range{start: %{line: sl}, end: %{line: el}} = range, _)
      when sl < 0 or el < 0 do
    {:error, {:invalid_range, range}}
  end

  def to_native(%Types.Range{} = range, context_document) do
    Conversions.to_elixir(range, context_document)
  end
end
```

### 5c. Document.Container — context propagation through nested structs

**Reference**: `projects/lexical_shared/lib/lexical/document/container.ex`

```elixir
defprotocol Lexical.Document.Container do
  @fallback_to_any true
  @spec context_document(t, maybe_context_document()) :: maybe_context_document()
  def context_document(t, parent_context_document)
end

# Fallback: try common field names
defimpl Lexical.Document.Container, for: Any do
  def context_document(%{document: %Document{} = document}, _), do: document

  def context_document(%{lsp: lsp_request}, parent) do
    context_document(lsp_request, parent)
  end

  def context_document(%{text_document: %{uri: uri}}, parent) do
    case Document.Store.fetch(uri) do
      {:ok, document} -> document
      _ -> parent
    end
  end

  def context_document(_, parent), do: parent
end
```

**Why it works**: Convertible's `Any` fallback walks struct fields recursively, so most types convert automatically. Only types with special semantics (Range with encoding differences, Location with URI resolution) need explicit implementations. Container protocol lets conversion find the right document context without threading it through every function.

---

## 6. StructAccess — Bracket Notation for Structs

A 30-line macro that implements the `Access` behaviour. Drop `use StructAccess` into any struct to enable `my_struct[:field]`.

**Reference**: `projects/lexical_shared/lib/lexical/struct_access.ex`

```elixir
defmodule Lexical.StructAccess do
  defmacro __using__(_) do
    quote location: :keep do
      def fetch(struct, key) when is_map_key(struct, key) do
        {:ok, Map.get(struct, key)}
      end

      def fetch(_, _), do: :error

      def get_and_update(struct, key, function) when is_map_key(struct, key) do
        old_value = Map.get(struct, key)
        case function.(old_value) do
          {current_value, updated_value} -> {current_value, Map.put(struct, key, updated_value)}
          :pop -> {old_value, Map.put(struct, key, nil)}
        end
      end

      def get_and_update(struct, key, _function) do
        {{:error, {:nonexistent_key, key}}, struct}
      end

      def pop(struct, key) when is_map_key(struct, key) do
        {Map.get(struct, key), struct}
      end

      def pop(struct, _key), do: {nil, struct}
    end
  end
end
```

Used by: `Document.Position`, `Document.Range`, `Document.Location`, `Search.Indexer.Entry`.

**Why it works**: Eliminates 25 lines of boilerplate per struct. The `is_map_key` guard catches invalid keys at the boundary.

---

## 7. Proto DSL — Layered Macro Composition

Generate struct + typespec + parser + JSON encoder + Access protocol + metadata from a single declaration. Each concern is a separate macro module that composes into the whole.

**Reference**: `apps/proto/lib/lexical/proto/type.ex`

```elixir
defmacro deftype(types) do
  caller_module = __CALLER__.module

  quote location: :keep do
    unquote(Json.build(caller_module))        # Jason.Encoder impl
    unquote(Inspect.build(caller_module))     # custom Inspect impl
    unquote(Access.build())                   # Access protocol
    unquote(Struct.build(types, __CALLER__))  # defstruct + new/0 + new/1

    @type t :: unquote(Typespec.typespec(types, __CALLER__))

    unquote(Parse.build(types))               # parse/1 with type coercion
    unquote(Match.build(types, caller_module)) # pattern match macros
    unquote(Meta.build(types))                # __meta__/1, __meta__/2
  end
end
```

Request/notification macros layer on top, generating both LSP-wire and Elixir-friendly structs:

```elixir
defmacro defrequest(method, params_module_ast) do
  types = fetch_types(params_module_ast, __CALLER__)

  quote location: :keep do
    defmodule LSP do
      # JSON-RPC 2.0 wire format (camelCase, id, jsonrpc fields)
      unquote(Message.build({:request, :lsp}, method, lsp_types, ...))
    end

    # Elixir-friendly version (snake_case, Document instead of TextDocumentIdentifier)
    unquote(Message.build({:request, :elixir}, method, elixir_types, ...))

    # Encoding: Elixir struct → LSP struct → JSON
    defimpl Jason.Encoder, for: unquote(caller.module) do
      def encode(request, opts), do: Jason.Encoder.encode(request.lsp, opts)
    end
  end
end
```

**Sub-macro responsibilities**:
- `Struct.build/2` — `@enforce_keys`, `defstruct`, `new/0`, `new/1`
- `Access.build/0` — `fetch`, `get_and_update`, `pop`
- `Parse.build/1` — recursive `parse/1` with type coercion for optional/nested types
- `Meta.build/1` — `__meta__(:param_names)`, `__meta__(:types)` for runtime inspection
- `Typespec.build/2` — `@type t :: ...` from DSL type descriptions
- `Json.build/1` — `Jason.Encoder` implementation
- `Inspect.build/1` — custom `Inspect` implementation

**Why it works**: Each sub-macro is independently testable. Adding a new concern (e.g., validation) means writing one new macro module and adding one line to `deftype`. The layering means `defrequest` reuses everything from `deftype` without duplication.

---

## 8. @before_compile for Compile-Time Code Generation

Collect metadata during compilation, then generate dispatch functions in a `@before_compile` hook.

**Reference**: `apps/proto/lib/lexical/proto/decoders.ex`

```elixir
# Step 1: Module declares it wants decoders generated
defmacro __using__(opts) when is_list(opts) do
  function_name = case Keyword.get(opts, :decoders) do
    :notifications -> :for_notifications
    :requests -> :for_requests
  end

  quote do
    @before_compile {Decoders, unquote(function_name)}
  end
end

# Step 2: Each defnotification/defrequest registers itself in CompileMetadata
# (happens as modules are compiled)

# Step 3: Before compilation finishes, generate decoder functions
defmacro for_notifications(_) do
  notification_modules = CompileMetadata.notification_modules()
  notification_matchers = Enum.map(notification_modules, &build_notification_matcher_macro/1)
  notification_decoders = Enum.map(notification_modules, &build_notifications_decoder/1)

  quote do
    unquote_splicing(notification_matchers)

    @spec decode(String.t(), map()) :: {:ok, notification} | {:error, any}
    unquote_splicing(notification_decoders)
  end
end
```

Result: a `decode/2` function with one clause per notification type, generated from the declarations. No hand-maintained dispatch table.

---

## 9. defenum DSL — Bidirectional Enum Encoding

Generate atoms-to-values and values-to-atoms conversion from a keyword list declaration.

**Reference**: `apps/proto/lib/lexical/proto/enum.ex`

```elixir
defmacro defenum(opts) do
  quote location: :keep do
    @type name :: unquote(name_type)
    @type value :: unquote(value_type)
    @type t :: name() | value()

    unquote(parse_functions(opts))      # value → atom
    unquote_splicing(encoders(opts))    # atom → value
    unquote_splicing(enum_macros(opts)) # macros for pattern matching
  end
end

# Usage
defenum error: 1, warning: 2, information: 3, hint: 4
# Generates:
#   parse(1) -> {:ok, :error}
#   encode(:error) -> {:ok, 1}
#   defmacro error(), do: :error   (for use in guards/patterns)
```

---

## 10. defdelegate Facade with Compile-Time Config

Use `Application.compile_env/3` to select implementation at compile time, expose via `defdelegate`.

**Reference**: `apps/server/lib/lexical/server/transport.ex`

```elixir
defmodule Transport do
  @callback write(Jason.Encoder.t()) :: Jason.Encoder.t()

  @implementation Application.compile_env(:server, :transport, StdIO)

  defdelegate write(message), to: @implementation
end
```

Also used in search store backend selection:

```elixir
@backend Application.compile_env(:remote_control, :search_store_backend, Store.Backends.Ets)
```

**Why it works**: Swap implementations via config (prod vs test) without touching code. The behaviour ensures all implementations satisfy the same contract.

---

## 11. gen_event PubSub with Handler Registration

Broadcast events to registered listeners using `:gen_event`. Handlers declare interest in specific event types.

**Reference**: `apps/remote_control/lib/lexical/remote_control/dispatch.ex`

```elixir
defmodule Dispatch do
  @handlers [PubSub, Handlers.Indexing]

  def start_link(opts) do
    case :gen_event.start_link(name()) do
      {:ok, pid} = success ->
        Enum.each(@handlers, &:gen_event.add_handler(pid, &1, []))
        success
      error -> error
    end
  end

  def register_listener(listener_pid, message_types) when is_list(message_types) do
    :gen_event.call(__MODULE__, PubSub, PubSub.register_message(listener_pid, message_types))
  end

  def broadcast(message) do
    :gen_event.notify(__MODULE__, message)
  end
end
```

PubSub handler routes messages to registered PIDs:

```elixir
defmodule PubSub do
  @behaviour :gen_event

  def handle_event(message, %State{} = state) do
    message_type = extract_message_type(message)

    state
    |> State.registrations(message_type)
    |> Enum.each(&send(&1, message))

    {:ok, state}
  end
end
```

---

## 12. Progress Tracking with Closures

Wrap long-running operations with progress begin/complete events. Uses closures for guaranteed cleanup.

**Reference**: `apps/remote_control/lib/lexical/remote_control/progress.ex`

```elixir
defmacro __using__(_) do
  quote do
    import unquote(__MODULE__), only: [with_progress: 2]
  end
end

def with_progress(label, func) when is_function(func, 0) do
  on_complete = begin_progress(label)

  try do
    func.()
  after
    on_complete.()  # always fires, even on exception
  end
end

def with_percent_progress(label, max, func) when is_function(func, 1) do
  {report_progress, on_complete} = begin_percent(label, max)

  try do
    func.(report_progress)  # caller invokes report_progress.(delta) periodically
  after
    on_complete.()
  end
end

defp begin_progress(label) do
  RemoteControl.broadcast(project_progress(label: label, stage: :begin))

  fn ->
    RemoteControl.broadcast(project_progress(label: label, stage: :complete))
  end
end
```

**Why it works**: `begin_progress/1` returns a closure that captures the label. The `try/after` ensures completion is always broadcast, even on crash. The progress reporting callback is injected into the work function, keeping tracking decoupled from business logic.

---

## 13. ETS Schema with Versioned Migrations

Macro-based schema definition for ETS tables with version tracking and record-based query helpers.

**Reference**: `apps/remote_control/lib/lexical/remote_control/search/store/backends/ets/schema.ex`

```elixir
defmacro __using__(opts) do
  version = Keyword.fetch!(opts, :version)

  quote do
    @behaviour unquote(__MODULE__)
    @version unquote(version)
    import unquote(__MODULE__), only: [defkey: 2]

    def version, do: @version
    def index_file_name, do: "source.index.v#{@version}.ets"
    def table_name, do: :"lexical_search_v#{@version}"
    def table_options, do: [:named_table, :set]
    def migrate(entries), do: {:ok, entries}

    defoverridable migrate: 1, index_file_name: 0, table_options: 0
  end
end

# Generates Record definitions with query wildcards
defmacro defkey(name, fields) do
  query_keys = Enum.map(fields, fn name -> {name, :_} end)
  query_record_name = :"query_#{name}"

  quote location: :keep do
    require Record
    Record.defrecord(unquote(name), unquote(fields))
    Record.defrecord(unquote(query_record_name), unquote(name), unquote(query_keys))
  end
end
```

**Why it works**: Version in the table/file name allows smooth migrations. `defkey` generates both the record for storage and a wildcard-filled query record for `ets:match_object/2`.

---

## 14. Compile-Time Union Typespec Generation

Collect all modules of a category during compilation, then generate a union type from their `t()` types.

**Reference**: `apps/proto/lib/lexical/proto/typespecs.ex`

```elixir
defmacro __using__(opts) do
  group_name = Keyword.fetch!(opts, :for)
  modules = case group_name do
    :notifications -> CompileMetadata.notification_modules()
    :requests -> CompileMetadata.request_modules()
    :responses -> CompileMetadata.response_modules()
    :types -> CompileMetadata.type_modules()
  end

  quote do
    unquote(build_typespec(singular(group_name), modules))
  end
end

def build_typespec(type_name, modules) do
  spec = Enum.reduce(modules, nil, fn
    module, nil -> quote(do: unquote(module).t())
    module, spec -> quote(do: unquote(module).t() | unquote(spec))
  end)

  quote do
    @type unquote({type_name, [], nil}) :: unquote(spec)
  end
end
```

Result: `@type notification :: LogMessage.t() | ShowMessage.t() | PublishDiagnostics.t() | ...` — automatically kept in sync with declared notification modules.

---

## Pattern Taxonomy

| Category | Patterns | Core Idea |
|----------|----------|-----------|
| **State Management** | Nested State Module, Composable States | Pure state logic separate from OTP callbacks |
| **Extensibility** | @handlers, Detection, Translatable, Convertible | Behaviour/protocol + explicit registration |
| **Code Generation** | Proto DSL, @before_compile, defenum, Union Typespecs | Declare intent, generate boilerplate |
| **Event Flow** | Dispatch.Handler, PubSub, Progress | Declarative event interest, generated routing |
| **Utility** | StructAccess, defdelegate facade | Small macros that eliminate repetitive code |
| **Data Modeling** | Document.Container, ETS Schema | Convention-based discovery + versioned storage |
