# 候选人列表排序/过滤安全重设计（可运行参考实现）

运行测试：

```bash
ruby -Ilib:test test/candidate_list_query_test.rb
```

核心文件：`lib/candidate_list_query.rb`。

## 1. 安全边界

不要用正则判断“排序字段是否像合法列名”，也不要继续把 HTTP 参数交给
`order(params[:sort])` 或原始 `where`。

统一改成：

```text
HTTP 参数
  → 版本化参数兼容层
  → 稳定字段 key（例如 applied_at，而不是 candidates.applied_at）
  → 字段策略：当前角色是否可看、可排序、可过滤、可用哪些操作符
  → 类型转换
  → 服务端注册表中预定义的 Arel 列/表达式
  → Active Record 查询
```

客户端输入永远不会成为 SQL 标识符；字段、排序表达式、JOIN 和操作符都来自服务端
allowlist。过滤值经过严格类型转换，并由 Arel/Active Record 负责引用。

## 2. 字段能力注册表

每个字段显式声明：

- 稳定 API key；
- 实际列或服务端表达式；
- 字段类型；
- 哪些角色可见；
- 是否允许排序；
- 是否允许过滤；
- 允许的操作符；
- 老参数名/前端历史字段名；
- 枚举值等校验规则。

示例中：

- `name`、`status`、`applied_at` 对企业招聘角色开放；
- `expected_salary` 只对薪酬/平台角色开放；
- `interviewing_elsewhere` 只对平台角色开放；
- `salary`、`expectedSalary`、`other_offers` 等历史名称只是显式 alias，不会绕过权限。

未知字段和“字段存在但无权访问”返回完全相同的通用错误，避免攻击者据此枚举隐藏字段。
详细原因只写服务端审计日志。

## 3. 排序

`SortCompiler` 只从注册表取 Arel 列，并把 direction 限制为 `asc/desc`。

无论业务字段是否重复，都追加唯一、非敏感的主键倒序作为 tie-breaker，避免 offset
翻页时重复或漏数据。默认顺序也必须是硬编码顺序，并使用 `reorder` 清除继承来的或
default scope 中的未知排序。

隐藏字段被拒绝后，不会进入 SQL `ORDER BY`，因此“排序 + 翻页推断”的信道被直接关闭。

## 4. 过滤

新接口建议使用结构化参数：

```json
{
  "filters": [
    { "field": "status", "op": "in", "value": ["interview", "offer"] },
    { "field": "applied_at", "op": "gte", "value": "2026-01-01T00:00:00Z" }
  ]
}
```

`FilterCompiler` 对每个节点执行：

1. 字段是否存在；
2. 当前角色是否有该字段的过滤权限；
3. 操作符是否在该字段的 allowlist 中；
4. 值是否能转换为声明类型；
5. 再生成参数化/安全引用的 Arel 条件。

不要接受任意嵌套 Hash，例如
`filter[expected_salary][gt]=1` 后直接拼列名；也不要允许客户端传入原始 SQL、Arel
SQL literal、表名、JSON path 或任意关联名。关联排序/过滤只能使用注册表中预定义的
Arel 表达式和 JOIN。

## 5. 老接口兼容

兼容的是“已知旧参数名和语义”，不是“继续接受任意字段名”。

推荐同时保留两层：

- v2： canonical `sort` / `filters`；
- v1：扁平参数，例如 `q`、`status`、`applied_from`、`applied_to`。

`LegacyFilterTranslator` 把 v1 参数转换成同一套 canonical nodes；旧排序名通过字段
`aliases` 解析。所有版本最终调用同一个 `CandidateList::Query`。

迁移几十种组合时：

1. 从前端代码、访问日志和接口文档收集全部排序/筛选参数；
2. 为每个已知参数建立 alias 或 `LegacyParam`；
3. 上线 shadow 审计：记录原始参数、解析结果、角色、租户、是否会被拒绝；
4. 补齐角色矩阵和组合测试；
5. 切到 enforce：未知/无权字段统一 `400 invalid_query`，或 v1 过渡期记录指标后回退默认查询，但绝不能把该字段送入 SQL。

隐藏字段不属于需要保留的合法兼容能力；即使老接口曾经意外接受它们，也必须拒绝。

## 6. Rails Controller 示例

```ruby
class Company::CandidatesController < Company::ApplicationController
  def index
    candidates = CandidateList::Pagination.offset(
      candidate_query.call(
        sort: params[:sort],
        direction: params[:direction],
        filters: canonical_filters,
        legacy_filters: legacy_filter_params
      ),
      page: params[:page],
      per_page: params[:per_page]
    )

    render json: CandidateSerializer.new(candidates, fields: permitted_response_fields)
  rescue CandidateList::InvalidQuery => e
    Rails.logger.info(
      event: "invalid_candidate_list_query",
      reason: e.reason,
      company_id: current_company.id,
      user_id: current_user.id
    )

    render json: { error: { code: "invalid_query" } }, status: :bad_request
  end

  private

  def candidate_query
    CandidateList::Query.new(
      model: Candidate,
      # 关键：scope 必须先带租户/企业和数据权限，不能从 Candidate.all 开始。
      scope: current_company.candidates,
      catalog: CandidateList.candidate_catalog,
      role: current_user.list_role
    )
  end

  def canonical_filters
    Array(params[:filters]).map do |filter|
      {
        field: filter[:field],
        op: filter[:op],
        value: filter[:value]
      }
    end
  end

  def legacy_filter_params
    params.to_unsafe_h.except(
      "controller", "action", "format",
      "page", "per_page", "sort", "direction"
    )
  end
end
```

字段可见性如果依赖记录归属、HRBP 范围等动态策略，把 Catalog 中的静态 role 集合替换为
`FieldPolicy#permitted?(user, field, usage)`。但列表查询必须先应用租户和行级 scope，
避免通过排序/过滤探测 scope 外记录。

## 7. 前端改造

新增查询 schema 接口，例如：

```ruby
render json: { fields: CATALOG.metadata(current_user.list_role) }
```

前端根据 schema 渲染排序和筛选控件，并只提交 `field.key`。逐步删除各处手工拼接数据库
列名的代码；可以加 lint/静态扫描禁止新的模板字符串进入 `sort`、`order`、`sortBy`。

## 8. 还需要覆盖的测试

参考测试已经覆盖核心攻击路径。真实项目还应为以下入口复用同一套测试：

- JSON API、HTML 后台、CSV/Excel 导出；
- 保存的筛选器/智能文件夹；
- 报表、看板、异步导出任务；
- GraphQL/批量接口；
- 不同角色、租户隔离和动态字段权限；
- keyset cursor 的签名、过期和篡改。

如果数据量较大，建议把 offset 分页换成不透明、签名的 keyset cursor；cursor 中只放
canonical sort key 和排序值，服务端验签后使用。它不能替代字段授权，但能提供更稳定的
深分页。
