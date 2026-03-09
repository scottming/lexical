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
