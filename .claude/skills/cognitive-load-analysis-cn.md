# Lexical 模式的认知负荷分析

从五种基础认知操作的角度（基于 Barsalou 知觉符号系统理论），分析 Lexical 代码库如何降低认知负荷。

## 五种认知操作

按认知代价从低到高排列：

| 层级 | 操作 | 读者做什么 |
|------|------|-----------|
| 一阶 | **枚举** | 扫描、列举可见元素 |
| 一阶 | **对比** | 比较两个事物的异同 |
| 一阶 | **模拟** | 在脑中执行代码、追踪状态变化、预测结果 |
| 二阶 | **组合** | 将部件组装成整体 |
| 二阶 | **递归** | 在不同抽象层级重复应用模式 |

一阶操作代价低，二阶操作代价高。**模拟**是一阶操作中最昂贵的——需要同时维持心理状态、追踪控制流、预测副作用。

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
def snipe(%Setup{} = setup) do
  with {:ok, prepared} <- Transaction.prepare(setup),
       {:ok, result}   <- Submission.execute(prepared, setup) do
    {:ok, result}
  end
end
```

读者的模拟路径是**线性**的：step1 → step2 → 完成。不需要在工作记忆中维护分支树。每一步的名字（`Transaction.prepare`、`Submission.execute`）告诉你**做什么**，不需要展开函数体去模拟**怎么做**。

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
def prepare(%Setup{} = setup) do ...
```

读者不需要进入函数体、模拟数据流来确认输入类型。在签名处一眼对比：期望 Setup，传入的是 Setup 吗？完成。一次**对比**，零次**模拟**。

---

## 二阶操作：组合与递归

Lexical 在二阶操作上的处理更精妙，但使用频率较低：

### 组合 → Proto DSL 的分层宏设计

```
deftype = Json.build + Inspect.build + Access.build + Struct.build + Parse.build + Meta.build
defrequest = deftype + Message.build + Jason.Encoder
```

每一层只需理解自己的输入输出，不需要理解其他层的实现。组合的认知成本被**封装**在宏里，使用者看到的是一个 `deftype [name: string(), ...]`。

### 递归 → Convertible 协议的自动递归

```elixir
# Any fallback 自动递归转换 struct 字段
def to_native(%_struct{} = struct, context_document) do
  struct |> Map.from_struct() |> Helpers.apply(&Convertible.to_native/2, context_document)
end
```

读者不需要自己做递归思考——协议框架替你递归了。递归的认知负荷被框架吸收，读者只需维持扁平的心理模型。

---

## 总结

| 认知操作 | Lexical 的降低策略 | 使用频率 |
|---------|-------------------|---------|
| **模拟** | 纯函数与副作用分离（State Module、Detection、`with` 管道） | **最高** |
| **枚举** | 聚集到单一位置（@handlers、@enforce_keys、@impl） | 高 |
| **对比** | 统一接口（Protocol、Behaviour、签名类型标注） | 中 |
| **组合** | 封装在宏里，使用者只见声明式 API（Proto DSL） | 低 |
| **递归** | 框架自动递归，使用者不需要递归思考（Convertible Any） | 低 |

### 一句话总结

**把需要同时模拟的东西拆开，让读者一次只追踪一条因果链。** 嵌套 State 模块、Detection behaviour、`with` 管道，本质上都在做同一件事。

---

## 深入分析：递归与认知负荷

递归是认知代价最高的操作，因为读者必须**同时在工作记忆中维持多个栈帧**——模拟"模拟"，一个二阶操作。Lexical 的策略是：**把递归降级为更廉价的认知操作**，让读者根本不需要递归思考。

### 技巧一：框架吸收遍历（递归 → 单步模拟）

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

回调函数只处理**单个节点**。`Macro.postwalk` 承担了所有遍历逻辑。这和 Nested State Module 是同一个原理——**切断模拟链**，把"如何遍历"和"每步做什么"拆开。

| 框架 | 读者的心理模型 | 使用场景 |
|------|--------------|---------|
| `Macro.prewalk` | "自顶向下，对每个节点执行 X" | analysis.ex, variable.ex, quoted.ex |
| `Macro.postwalk` | "自底向上，对每个节点执行 X" | string.ex |
| `Macro.traverse` | "进入节点时做 X，离开时做 Y" | analysis.ex, error.ex |
| `Zipper.traverse` | "在范围内的每个节点执行 X" | ast.ex `traverse_in/4` |
| `Zipper.find` | "找到第一个满足条件的节点" | remove_unused_alias.ex |
| Protocol dispatch | "转换这个东西" | convertible.ex |

### 技巧二：多子句模式匹配镜像数据结构（递归 → 枚举）

```elixir
# apps/common/lib/future/code/typespec.ex
defp collect_vars({:type, _anno, _kind, args}) when is_list(args) do
  Enum.flat_map(args, &collect_vars/1)        # 有子类型 → 展开
end

defp collect_vars({:paren_type, _anno, [type]}) do
  collect_vars(type)                           # 括号包裹 → 剥掉
end

defp collect_vars({:var, _anno, var}) do
  [erl_to_ex_var(var)]                         # 变量 → 收集（基础情况）
end

defp collect_vars(_) do
  []                                           # 其他 → 忽略（基础情况）
end
```

读者的心理模型不是"递归遍历类型树"，而是**枚举四种情况**：
1. 有子类型的类型 → 展开
2. 括号 → 剥掉
3. 变量 → 收集
4. 其他 → 忽略

每个子句独立可读。这就是"结构递归"（structural recursion）——函数的 clause 结构镜像了数据的结构，一一对应。`Enum.flat_map(args, &collect_vars/1)` 把"对每个元素递归"表达为"对列表做 flat_map"——读者看到的是**迭代**，不是递归。

### 技巧三：尾递归伪装成循环（递归 → 循环模拟）

```elixir
# apps/remote_control/lib/lexical/remote_control/search/indexer/source/reducer.ex
defp maybe_pop_block(%__MODULE__{} = reducer) do
  if block_ended?(reducer) do
    reducer
    |> pop_block()
    |> maybe_pop_block()   # 尾递归
  else
    reducer
  end
end
```

读者的心理模型是一个 **while 循环**："只要 block 结束了，就弹出，直到没有需要弹出的"。不需要维持多个栈帧——只有一个 `reducer` 在不断变化。

关键细节：**条件检测、状态变换、递归**被拆成三个独立关注点：
- `block_ended?` — 纯判断，不修改状态
- `pop_block` — 纯变换，不判断也不递归
- `maybe_pop_block` — 只做"判断 + 调用 + 递归"的骨架

### 技巧四：协议分发隐藏递归（递归 → 不可见）

```elixir
# 调用者写：
Convertible.to_native(some_nested_struct, doc)

# 实际发生的递归：
# 1. Any 实现：Map.from_struct → 对每个字段调用 to_native
# 2. List 实现：对每个元素调用 to_native
# 3. Map 实现：对每个值调用 to_native
# 4. 具体类型实现：做特定转换
```

调用者**根本不知道这里有递归**。他看到的是一个函数调用，返回一个结果。递归被协议的多态分发完全吸收了。这是降低递归认知成本的极致形态：**消除读者感知到递归存在的必要**。

### 技巧五：`update_in` 做路径递归（递归 → 声明式）

```elixir
# reducer.ex
hierarchy =
  update_in(reducer.block_hierarchy, id_path, fn current ->
    Map.put(current, block.id, %{})
  end)
```

嵌套 map 的更新本质上是递归的（沿路径逐层深入），但 `update_in` 把它变成了声明式："在这个路径上，做这个操作"。读者不需要想"第一层打开、第二层打开、修改、第二层关上、第一层关上"。

### 反面模式：Lexical 中难读的递归

为了对比，看看 Lexical 中少数需要真正递归思考的地方：

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

这个函数需要读者同时追踪：accumulator 在变化、两条递归分支（args 和 list）、`||` 短路语义、以及路径是如何从内到外构建的。它是 Lexical 中认知成本最高的递归之一。

但注意：Lexical 把它**封装在 `path_at/2` 后面**，调用者永远不直接接触这个递归。

### 递归降级策略总结

| 策略 | 递归被降级为 | 读者的心理模型 | 使用频率 |
|------|------------|--------------|---------|
| 框架吸收遍历 | 单步模拟 | "对每个节点做 X" | **最高** |
| 多子句镜像数据结构 | 枚举 | "这几种情况各做什么" | 高 |
| 尾递归 | 循环模拟 | "一直做直到条件不满足" | 中 |
| 协议分发 | 不可见 | "转换这个东西"（不知道有递归） | 中 |
| `update_in` / 路径式 | 声明式 | "在这个路径上做这个操作" | 低 |

### 递归的一句话总结

**好的递归不是写得更聪明的递归，而是让读者不需要递归思考的递归。** 最好的递归代码，读者甚至不知道它在递归。
