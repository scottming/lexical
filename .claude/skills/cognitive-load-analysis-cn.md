# Lexical 模式的认知负荷分析

从五种基础认知操作和四种桥接机制的角度（基于 Barsalou 知觉符号系统理论），分析 Lexical 代码库如何降低认知负荷。

## 五种认知操作

人类阅读代码时动用三种**元素操作**（大脑对每个代码单元做什么）和两种**结构维度**（复杂度沿哪个轴增长）：

```
元素操作（每个单元的认知成本）：
  枚举 ─── 激活概念："这是什么？"
  对比 ─── 绑定类型："A 还是 B？"
  模拟 ─── 运行因果链："如果 X，那会怎样？"

结构维度（复杂度沿哪个轴增长）：
  组合 ─── 同层级单元变多（水平）
  嵌套 ─── 抽象层级变深（垂直）
```

元素操作有内在的成本梯度：**枚举几乎免费，对比在近距离时低成本，模拟成本高**（受工作记忆 ~4 项限制，Cowan 2001）。结构维度**没有固有成本**——它们的成本完全取决于内部需要什么元素操作：

- 好的组合 → 读者只需**枚举**部件 → 低成本
- 好的嵌套 → 读者只需**对比**各层接口 → 低成本
- 差的组合 → 读者必须同时**模拟**所有部件 → 高成本
- 差的嵌套 → 读者必须**模拟**多个栈帧 → 高成本

**成本 = 元素操作成本 × 结构复杂度**，而非结构复杂度本身。这就是为什么结构良好的多层代码可以比强迫模拟的"扁平"代码更便宜。

四种**桥接机制**连接这些操作：
- **固化**（entrenchment）：重复经验将模拟 → 枚举（第 N 次见到一个模式，你识别它而非追踪它）
- **模式补全**（pattern completion）：好的组合触发对未见部分的自动预测（Barsalou 2009）
- **同构**（isomorphism）：当嵌套层级遵循相同结构模式时，理解一层即可预测其余——模式补全从水平维度延伸到垂直维度（Bastos et al. 2012, Martins et al. 2015）
- **生产力**（productivity）：组合 × 嵌套共同从有限模块产生无限表达力（Barsalou 1999）

---

## 核心策略：降低模拟成本

模拟是阅读代码时的主要认知成本。Lexical 最常用的技巧是**切断模拟链**——把需要同时模拟的事物拆开，让读者一次只模拟一件事。

### 1. 嵌套 State 模块 → 切断「OTP 协议 + 业务逻辑」的联合模拟

读一个普通 GenServer，需要**同时**模拟：
- OTP 回调语义（`{:noreply, state}` vs `{:reply, ...}` vs `{:stop, ...}`）
- 业务状态如何变化
- 哪些地方有副作用

Lexical 把它拆成两条独立的模拟链：

```elixir
# 读 State 模块时：只模拟纯数据变换
def on_nodeup(%State{} = state, node_name) do
  # 输入 state → 输出 state，没有 {:noreply, ...} 干扰
  %{state | status: :started}
end

# 读 GenServer 时：只模拟调度，不需要理解业务
def handle_info({:nodeup, node, _}, %State{} = state) do
  state = State.on_nodeup(state, node)  # 一个函数调用，不需要展开
  {:noreply, state}
end
```

**认知效果**：一条长模拟链变成两条短的、独立的模拟链。读 State 时不用想 OTP，读 GenServer 时不用想业务逻辑。

这是 Lexical 中**使用频率最高**的技巧。ProjectNode、Proxy 的三个状态模块（BufferingState / ProxyingState / DrainingState）、PubSub.State 都是这个模式。

### 2. Behaviour + `use` 宏 → 切断「框架理解 + 实现细节」的联合模拟

```elixir
defmodule Detection.Alias do
  use Detection  # 一行声明，不需要展开

  @impl Detection
  def detected?(analysis, position) do
    # 只需要模拟这一个函数的逻辑
  end
end
```

`use Detection` 做了三件事（注册 behaviour、导入 helpers、设置回调），但读者**不需要展开它**就能理解这个模块在做什么。`@impl Detection` 标注进一步确认了"这是个回调实现"，避免读者去模拟"这个函数会被谁调用"。

### 3. `with` 线性管道 → 消除分支模拟

```elixir
# apps/server/lib/lexical/server.ex
def handle_message(%_{} = request, %State{} = state) do
  with {:ok, handler} <- fetch_handler(request),
       {:ok, req} <- Convert.to_native(request) do
    TaskQueue.add(request.id, {handler, :handle, [req, state.configuration]})
  end
end
```

读者的模拟路径是**线性**的：step1 → step2 → 完成。不需要在工作记忆中维护分支树。每一步的名字（`fetch_handler`、`Convert.to_native`）告诉你**做什么**，不需要展开函数体去模拟**怎么做**。

---

## 第二常用策略：降低枚举成本

枚举是最廉价的认知操作，但 Lexical 通过**把需要枚举的东西聚集到一个位置**进一步降低成本。

### @handlers 列表 → 枚举范围从「整个代码库」缩小到「5 行」

```elixir
@handlers [
  Handlers.ReplaceRemoteFunction,
  Handlers.ReplaceWithUnderscore,
  Handlers.OrganizeAliases,
  Handlers.AddAlias,
  Handlers.RemoveUnusedAlias
]
```

"这个系统支持哪些 code action？"——枚举这 5 行即可，不需要搜索代码库。

### @enforce_keys → 枚举必填字段

```elixir
@enforce_keys [:project, :cookie, :status]
defstruct [:project, :port, :cookie, :stopped_by, :started_by, :status]
```

"哪些字段是必须的？"——枚举 `@enforce_keys`，而不是去模拟所有构造路径。

### @impl 标注 → 枚举回调边界

不标 `@impl` 时，读者必须**对比** behaviour 定义来判断哪些函数是回调、哪些是内部函数。标了之后，枚举 `@impl` 标注即可。这把一个**对比操作降级为了枚举操作**。

---

## 第三常用策略：降低对比成本

### 统一接口 → 消除"这个 vs 那个"的结构性对比

Translatable 协议让所有 completion candidate 类型共享同一个 `translate/3` 接口。读者理解了一个实现，就理解了所有实现的**形状**——只需要对比**内容**差异，不需要对比**结构**差异。

```elixir
# 每个实现的签名完全相同，只有函数体不同
defimpl Translatable, for: Candidate.Function do
  def translate(function, builder, env), do: ...
end

defimpl Translatable, for: Candidate.Macro do
  def translate(macro, builder, env), do: ...
end
```

### `%Struct{} = param` → 类型对比在签名处完成

```elixir
# apps/remote_control/lib/lexical/remote_control/code_intelligence/entity.ex
def resolve(%Analysis{} = analysis, %Position{} = position) do ...
```

读者不需要进入函数体、模拟数据流来确认输入类型。在签名处一眼对比：期望 Analysis 和 Position，传入的类型对吗？完成。一次**对比**，零次**模拟**。

---

## 结构维度：组合与嵌套

Lexical 在结构维度上的处理更精妙。概览两个典型例子（详见后面的深入分析）：

### 组合 → Proto DSL 的分层宏设计

```
deftype = Json.build + Inspect.build + Access.build + Struct.build + Parse.build + Meta.build
defrequest = deftype + Message.build + Jason.Encoder
```

每一层只需理解自己的输入输出，不需要理解其他层的实现。组合的认知成本被**封装**在宏里，使用者看到的是一个 `deftype [name: string(), ...]`。

### 嵌套 → Convertible 协议的自动嵌套遍历

```elixir
# Any fallback 自动递归转换 struct 字段
def to_native(%_struct{} = struct, context_document) do
  struct |> Map.from_struct() |> Helpers.apply(&Convertible.to_native/2, context_document)
end
```

读者不需要思考嵌套深度——协议框架替你遍历了。嵌套的认知负荷被框架吸收，读者只需维持扁平的心理模型。

---

## 总结

| 元素操作 | Lexical 的降低策略 | 使用频率 |
|---------|-------------------|---------|
| **模拟** | 纯函数与副作用分离（State Module、Detection、`with` 管道） | **最高** |
| **枚举** | 聚集到单一位置（@handlers、@enforce_keys、@impl） | 高 |
| **对比** | 统一接口（Protocol、Behaviour、签名类型标注） | 中 |

| 结构维度 | Lexical 的降低策略 | 使用频率 |
|---------|-------------------|---------|
| **组合** | 扁平列表、管道、分层宏、透明封装、闭包（详见深入分析） | 高 |
| **嵌套** | 门面、清晰边界、薄编排层、封装、同构、框架吸收遍历（详见深入分析） | 高 |

### 一句话总结

**把需要同时模拟的东西拆开，让读者一次只追踪一条因果链。** 嵌套 State 模块、Detection behaviour、`with` 管道，本质上都在做同一件事。

---

## 深入分析：嵌套与认知负荷

嵌套是代价最高的结构维度，因为读者必须**同时在工作记忆中维持多个抽象层级**——受限于约 4 个层级（Cowan 2001）。

在代码中，嵌套有两种主要形态：

- **抽象层级嵌套**：模块 A 调用模块 B 调用模块 C……读者需要跳转多个文件才能理解一个业务操作。这是日常开发中最常见的嵌套形态。
- **代码递归**：函数调用自身，读者需要在脑中维持多个栈帧。出现频率较低但认知成本极高。

Lexical 的策略：**把嵌套降级为更廉价的认知操作**，让读者停留在当前层级，通过命名、边界或同构预测其余层级。

---

### 一、抽象层级嵌套

Lexical 的 LSP 补全请求从 stdin 到返回结果，途经约 15 个模块（StdIO → Server → JsonRpc → Convert → TaskQueue → Handler → CodeIntelligence → Env → Api → erpc → RemoteControl → Completion → …返回… → Translatable → Convert → Transport）。如果读者需要同时理解所有层级，认知成本将难以承受。

Lexical 通过以下技巧将这种深度控制在读者可管理的范围内。

#### 门面模式收敛入口（嵌套 → 枚举）

```elixir
# apps/remote_control/lib/lexical/remote_control.ex — 22 个 defdelegate
defdelegate compile_document(project, document), to: Api.Proxy
defdelegate complete(env), to: RemoteControl.Completion
defdelegate resolve_entity(analysis, position), to: CodeIntelligence.Entity
defdelegate broadcast(message), to: Dispatch
# ... 共 22 个
```

`RemoteControl` 是远程应用的门面——调用者只需知道一个模块，不需要知道背后有 Proxy、Dispatch、Completion、CodeIntelligence 等十几个内部模块。嵌套深度从"在 N 个模块中搜索目标函数"收敛为"在一个模块中枚举"。

同样的模式：`Transport` 用 `defdelegate write(message), to: @implementation` 把传输实现（StdIO vs NoOp）隐藏在编译期配置后面。

#### 清晰边界阻止下探（嵌套 → 命名预测）

```elixir
# apps/remote_control/lib/lexical/remote_control/api.ex
def complete(%Project{} = project, %Env{} = env) do
  RemoteControl.call(project, RemoteControl, :complete, [env])
end

def resolve_entity(%Project{} = project, %Analysis{} = analysis, %Position{} = position) do
  RemoteControl.call(project, RemoteControl, :resolve_entity, [analysis, position])
end
```

`RemoteControl.Api` 是管理节点与项目节点之间的 RPC 边界。每个函数都是一行 `RemoteControl.call`。读者看到 `Api.complete(project, env)` 时，函数签名 `(%Project{}, %Env{})` 已经是完备的理解——"带着这个项目和这个环境，在远端执行补全"，**不需要下探**。

这个边界的价值不仅是封装，更是**阻止认知泄漏**：服务器端代码永远不需要理解远程节点的内部结构。

#### 薄编排层只做调度（嵌套 → 线性模拟）

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

Handler 是三步线性管道：获取分析 → 调用智能 → 包装响应。读者不需要下探 `CodeIntelligence.Completion` 就能理解这一层在做什么。每步的名字（`document_analysis`、`Completion.complete`、`Responses.Completion.new`）创建了足够精确的预测。

#### 封装复杂内部于简洁 API（嵌套 → 不可见）

```elixir
# apps/common/lib/lexical/ast.ex
# 公共 API：简洁的 {:ok, path} | {:error, _}
def path_at(%Analysis{} = analysis, %Position{} = position) do
  with {:ok, ast, _} <- from(analysis) do
    path_at(ast, position)
  end
end

# 内部实现：Lexical 中认知成本最高的递归之一（双分支 + accumulator + || 短路）
defp innermost_path({form, _, args}, acc, fun) when is_atom(form) and is_list(args) do
  case fun.({form, _, args}) do
    true -> {:ok, [{form, _, args} | acc]}
    false ->
      innermost_path_args(args, [{form, _, args} | acc], fun) ||
        innermost_path_list(args, [{form, _, args} | acc], fun)
  end
end
```

调用者永远不接触 `innermost_path/3`。同样的模式：`Env.new/3` 隐藏了 13+ 个 Detection 模块的组合，`CodeIntelligence.Completion.complete/4` 隐藏了过滤、翻译、构建的完整管线。

通用原则：**复杂度可以存在，但必须被封装在公共 API 后面，而非泄漏给调用者**。

#### 同构层级（嵌套 → 对比）

当同一层级内的多个模块遵循**相同的结构模式**时，理解一个即可预测其余——把嵌套从模拟降级为对比。Martins et al. (2015) 实验证实，自相似层级结构激活**默认模式网络**（DMN），产生压缩的内部规则表征；非自相似结构激活**额顶控制网络**，需要逐层独立处理。

Lexical 最清晰的同构出现在 **provider handler 层级**：所有 10 个 LSP handler 模块都遵循 `handle/2` → 调用 intelligence → `{:reply, response}`。读完 `Handlers.Completion` 后，读者无需下探即可预测 `Handlers.Hover`、`Handlers.GoToDefinition` 等的形状——心理模型是**在已知模式上做参数替换**，而非重新模拟。

同构延伸到其他层级：code action handler（5 个模块共享 `actions/3` + `kinds/0`）、document compiler（5 个共享 `recognizes?/1` + `compile/1` + `enabled?/0`）、indexer extractor（9 个共享 `extract/2`）。

#### 对比：跨层级的异构嵌套

Lexical 的 LSP 请求管线跨越约 6 个概念层级，每层有**不同**的结构模式：

```
Transport（字节 I/O）→ Server（OTP 路由）→ Convert（结构映射）→
TaskQueue（异步调度）→ Handler（领域分发）→ CodeIntelligence（业务逻辑）
```

读者必须为每层构建独立的心理模型——无法通过同构做跨层预测。这种异构成本是问题本身固有的（传输 ≠ 路由 ≠ 转换 ≠ 调度 ≠ 业务逻辑），但 Lexical 通过**精确命名**缓解：`StdIO`、`Convert.to_native`、`TaskQueue.add`、`handler.handle`——每个名字创建高精度预测，阻止读者下探。

---

### 二、代码递归——嵌套的特殊形态

代码递归是嵌套的一种特殊情况：函数调用自身，读者需要在脑中维持多个栈帧。Lexical 的策略是把递归降级为更廉价的认知操作，让读者**不以递归方式思考递归代码**。

#### 框架吸收遍历（嵌套 → 单步模拟）

Lexical 中**最常用**的递归处理方式。读者的心理模型是"对每个节点做 X"，而不是"递归遍历一棵树"。

```elixir
# apps/common/lib/lexical/ast/detection/string.ex
defp detect_string(paths, %Position{} = position) do
  {_, detected?} =
    Macro.postwalk(paths, false, fn
      ast, true  -> {ast, true}                     # 已找到，短路
      ast, false -> {ast, do_detect(ast, position)}  # 检测当前节点
    end)
  detected?
end
```

回调函数只处理**单个节点**。`Macro.postwalk` 承担了所有遍历逻辑——**切断模拟链**，把"如何遍历"和"每步做什么"拆开。

| 框架 | 读者的心理模型 | 使用场景 |
|------|--------------|---------|
| `Macro.prewalk` | "自顶向下，对每个节点执行 X" | analysis.ex, variable.ex, quoted.ex |
| `Macro.postwalk` | "自底向上，对每个节点执行 X" | string.ex |
| `Macro.traverse` | "进入节点时做 X，离开时做 Y" | analysis.ex, error.ex |
| `Zipper.traverse` | "在范围内的每个节点执行 X" | ast.ex `traverse_in/4` |
| `Zipper.find` | "找到第一个满足条件的节点" | remove_unused_alias.ex |
| Protocol dispatch | "转换这个东西" | convertible.ex |

#### 多子句镜像数据结构（嵌套 → 枚举）

```elixir
# apps/common/lib/future/code/typespec.ex
defp collect_vars({:type, _anno, _kind, args}) when is_list(args) do
  Enum.flat_map(args, &collect_vars/1)        # 有子类型 → 展开
end
defp collect_vars({:paren_type, _anno, [type]}), do: collect_vars(type)  # 括号 → 剥掉
defp collect_vars({:var, _anno, var}), do: [erl_to_ex_var(var)]          # 变量 → 收集
defp collect_vars(_), do: []                                             # 其他 → 忽略
```

读者的心理模型不是"递归遍历类型树"，而是**枚举四种情况**。函数的 clause 结构镜像了数据的结构（结构递归），`Enum.flat_map` 把"对每个元素递归"表达为**迭代**。

#### 尾递归伪装成循环（嵌套 → 循环模拟）

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

读者的心理模型是 **while 循环**："只要 block 结束了就弹出，直到没有需要弹出的"。不需要维持多个栈帧——只有一个 `reducer` 在不断变化。

#### 协议分发隐藏嵌套（嵌套 → 不可见）

```elixir
Convertible.to_native(some_nested_struct, doc)
# Any 实现自动递归：Map.from_struct → 对每个字段调用 to_native
# List/Map 实现自动递归：对每个元素/值调用 to_native
```

调用者**根本不知道这里有嵌套遍历**。多层遍历被协议的多态分发完全吸收。

#### `update_in` 声明式路径（嵌套 → 声明式）

```elixir
hierarchy = update_in(reducer.block_hierarchy, id_path, fn current ->
  Map.put(current, block.id, %{})
end)
```

嵌套 map 的更新本质上是递归的，但 `update_in` 把它变成声明式："在这个路径上，做这个操作"。

---

### 反面模式：嵌套成本居高不下的地方

**互相递归**——symbol 树构建中 `rebuild_structure` 和 `map_block_type` 互相调用，读者必须追踪**调用图**而非单个函数。

**混合 fold + 递归**——`do_collect_parents` 在 `Enum.reduce` 内部调用自身：迭代和递归的控制流交织，比任何一种单独使用都难理解。

---

### 嵌套降级策略总结

| | 策略 | 嵌套被降级为 | 读者的心理模型 | 使用频率 |
|-|------|------------|--------------|---------|
| **抽象层级** | 门面/defdelegate | 枚举 | "在一个模块中找到所有入口" | 高 |
| | 清晰边界 | 命名预测 | "Api.complete = RPC 调用，不需要下探" | 高 |
| | 薄编排层 | 线性模拟 | "获取 → 调用 → 包装，三步" | 高 |
| | 封装复杂内部 | 不可见 | "调用 path_at，不管内部多复杂" | 高 |
| | 同构层级 | 对比 | "和我已读过的 handler 形状一样" | 高 |
| **代码递归** | 框架吸收遍历 | 单步模拟 | "对每个节点做 X" | 最高 |
| | 多子句镜像数据 | 枚举 | "这几种情况各做什么" | 高 |
| | 尾递归 | 循环模拟 | "一直做直到条件不满足" | 中 |
| | 协议分发 | 不可见 | "转换这个东西" | 中 |
| | `update_in` / 路径式 | 声明式 | "在这个路径上做这个操作" | 低 |

### 嵌套的一句话总结

**好的嵌套不是更巧妙的抽象，而是让读者停留在当前层级的嵌套。** 抽象层级嵌套靠门面、边界和同构来控制；代码递归靠框架吸收和结构映射来消解。两者共同的原则：读者不需要下探就能建立正确的心理模型。

---

## 深入分析：组合与认知负荷

组合是一种结构维度。它的代价来自三步：
1. **理解各部件**（对每个部件做模拟）
2. **理解连接方式**（对接口做对比）
3. **理解涌现的整体**（对组合后的行为做模拟）

第 3 步是杀手。如果你必须**同时理解所有部件才能理解整体**，认知成本是乘法级的。Lexical 的策略是：**让读者能独立理解每个部件，然后通过廉价操作（枚举、对比、线性模拟）理解整体**。

### 技巧一：扁平组合（组合 → 枚举）

最简单的组合：把部件平铺在一个列表里，用 `flat_map` 合并结果。部件之间零耦合。

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

读者理解整体的方式：**枚举列表里的 5 个模块**。每个模块独立工作，互不影响，结果只是简单合并。不需要理解 handler A 才能理解 handler B。

同样的模式出现在编译器选择中：

```elixir
# apps/remote_control/lib/lexical/remote_control/build/document.ex
@compilers [Compilers.Config, Compilers.Elixir, Compilers.EEx, Compilers.HEEx, Compilers.NoOp]

def compile(document) do
  compiler = Enum.find(@compilers, & &1.recognizes?(document))
  compiler.compile(document)
end
```

**认知公式**：理解整体的成本 = Σ(理解每个部件) + 枚举成本，而不是 Π(理解每个部件)。

### 技巧二：管道组合（组合 → 线性模拟）

部件按顺序排列，每步的输出是下步的输入。读者只需线性追踪数据流。

```elixir
# apps/remote_control/lib/lexical/remote_control/api/proxy/buffering_state.ex
def flush(%__MODULE__{} = state) do
  {messages, commands} =
    state.buffer
    |> Enum.reverse()                          # Step 1: 反转
    |> Enum.split_with(fn value ->             # Step 2: 分组
      match?(mfa(module: Dispatch, function: :broadcast), value)
    end)

  {project_compile, document_compiles, reindex} = collapse_commands(commands)

  all_commands
  |> Enum.concat(collapse_messages(...))       # Step 3: 合并
  |> Enum.filter(&match?(mfa(), &1))           # Step 4: 过滤
  |> Enum.sort_by(fn mfa(seq: seq) -> seq end) # Step 5: 排序
end
```

读者的心理模型是**一条直线**：数据进来 → 变换1 → 变换2 → ... → 数据出去。不需要在工作记忆中维护分支。

**扁平组合 vs 管道组合**的区别：
- 扁平：部件**并行**，互不依赖，结果合并 → 枚举
- 管道：部件**串行**，前一步的输出是后一步的输入 → 线性模拟

两者都避免了"同时理解所有部件"。

### 技巧三：分层组合（组合 → 逐层模拟）

Lexical 中最精妙的组合技巧，集中体现在 Proto DSL 中。

```
用户看到的：
  deftype [name: string(), range: optional(range_type())]

实际展开的层次：
  Layer 0: deftype                      ← 用户写这个
  Layer 1: Json + Inspect + Access + Struct + Parse + Meta  ← deftype 组合这些
  Layer 2: 每个子宏内部的实现          ← 子宏独立工作
```

```elixir
# apps/proto/lib/lexical/proto/type.ex
defmacro deftype(types) do
  quote location: :keep do
    unquote(Json.build(caller_module))       # 关注点 1
    unquote(Inspect.build(caller_module))    # 关注点 2
    unquote(Access.build())                  # 关注点 3
    unquote(Struct.build(types, __CALLER__)) # 关注点 4
    unquote(Parse.build(types))              # 关注点 5
    unquote(Meta.build(types))               # 关注点 6
  end
end
```

再上一层，`defrequest` 组合了 `Message.build`（它复用了 deftype 的子宏）：

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

**认知效果**：读者在**任何一层**都不需要理解其他层。
- 用户写 `deftype`：只需知道"声明字段和类型"
- 维护者读 `deftype` 宏：只需知道"6 个子宏各做什么"（枚举）
- 维护者读 `Json.build`：只需知道"生成 Jason.Encoder 实现"

每一层是一个**抽象屏障**（abstraction barrier），阻止认知负荷向上泄漏。这正是函数式编程中组合的核心价值。

**对比反面模式**：如果 `deftype` 不分层，把所有生成逻辑写在一个宏里，读者就必须同时理解 JSON 编码、Inspect 实现、Access 协议、struct 定义、解析逻辑、元数据——6 个关注点交织在一起。

### 技巧四：透明组合（组合 → 不可见）

组合存在，但调用者不知道。

```elixir
# apps/remote_control/lib/lexical/remote_control/api/proxy/draining_state.ex
defstruct [:proxying_state, :buffering_state]

def new(%BufferingState{} = bs, %ProxyingState{} = ps) do
  %__MODULE__{buffering_state: bs, proxying_state: ps}
end

# 委托给内部组件——调用者不需要知道 DrainingState 由两部分组成
def drained?(%__MODULE__{} = state) do
  ProxyingState.empty?(state.proxying_state)
end

def add_mfa(%__MODULE__{} = state, mfa) do
  %__MODULE__{state | buffering_state: BufferingState.add_mfa(state.buffering_state, mfa)}
end
```

Proxy 的 `gen_statem` 调用 `DrainingState.add_mfa(state, mfa)` 时，它**不知道**这背后是 BufferingState 在工作。组合被 DrainingState 的接口封装了。

同样的模式出现在 Analysis 中（组合了 AST + Document + Scopes + Comments 为一个 struct）。

**认知原理**：和嵌套中"协议分发隐藏嵌套"是同一个思想——**如果组合对调用者不可见，它的认知成本就是零**。

### 技巧五：闭包组合（组合 → 单一概念）

用闭包把多步操作打包成一个"能力"，传给调用者。

```elixir
# apps/remote_control/lib/lexical/remote_control/progress.ex
def with_percent_progress(label, max, func) when is_function(func, 1) do
  {report_progress, on_complete} = begin_percent(label, max)

  try do
    func.(report_progress)  # 把"汇报进度"这个能力作为参数传入
  after
    on_complete.()           # 把"完成清理"封装在闭包里
  end
end

defp begin_percent(label, max) do
  # 返回两个闭包，各自捕获了 label 和 max
  report = fn delta -> broadcast(percent_progress(label: label, ...)) end
  complete = fn -> broadcast(project_progress(label: label, stage: :complete)) end
  {report, complete}
end
```

调用者的视角：

```elixir
with_percent_progress("Indexing", file_count, fn report ->
  Enum.each(files, fn file ->
    index(file)
    report.(1)  # 就像调用一个普通函数
  end)
end)
```

调用者不需要理解进度系统的内部结构（广播、事件、label 捕获）。他拿到的是一个**单一概念**："调用 `report.(1)` 就是汇报进度"。

**认知原理**：闭包把"组合后的行为"封装成一个可调用对象。读者不需要枚举部件、不需要对比接口——他只需要知道"调用这个函数做什么"。

### 组合降级策略总结

| 策略 | 组合被降级为 | 读者的心理模型 | 适用场景 |
|------|------------|--------------|---------|
| 扁平组合 | 枚举 | "N 个独立部件，合并结果" | @handlers、@compilers |
| 管道组合 | 线性模拟 | "数据经过一系列变换" | `with` 链、`\|>` 管道、Enum 链 |
| 分层组合 | 逐层模拟 | "这层做什么，不管下层怎么做" | Proto DSL、宏系统 |
| 透明组合 | 不可见 | "调用这个模块"（不知道内部有组合） | DrainingState、Analysis |
| 闭包组合 | 单一概念 | "调用这个函数" | Progress、资源管理 |

### 组合的一句话总结

**好的组合让你不需要同时理解所有部件就能理解整体。** 最好的组合代码，读者甚至不知道这里有多个部件。
