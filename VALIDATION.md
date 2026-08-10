# PoC 驗證報告

驗證日期:2026-08-10
驗證環境:macOS (Apple Silicon) + Podman 6.0.1(podman-compose 作為 compose provider)

## 步驟 1:環境建置與啟動

### 過程中發現並修正的問題

| # | 問題 | 原因 | 修正 |
|---|---|---|---|
| 1 | order-service 無法啟動:`8081: bind: address already in use` | 主機 8081 已被既有容器(product-sales-control-plane)占用 | docker-compose.yml 將 order-service 對外埠改為 **18081**(容器內仍為 8081) |
| 2 | 兩個微服務啟動即崩潰:`ILoggingEvent.getInstant()` NoSuchMethodError | `logstash-logback-encoder 7.4` 需要 logback 1.3+,但 Spring Boot 2.7.18 內建 logback **1.2.12** | 兩個 pom.xml 降版為 `logstash-logback-encoder 7.2`(最後支援 logback 1.2 的版本) |
| 3 | Zipkin 容器啟動即 SIGSEGV(exit 139),崩潰於 `libnetty_tcnative_linux_aarch_64` | `openzipkin/zipkin:2.24` 的 netty-tcnative 原生庫在 arm64(Apple Silicon)有已知崩潰問題 | 升級為 `openzipkin/zipkin:2.27` |

### 啟動結果

```
es-poc            Up (healthy)   0.0.0.0:9200->9200/tcp
kibana-poc        Up             0.0.0.0:5601->5601/tcp
filebeat-poc      Up
zipkin-poc        Up             0.0.0.0:9411->9411/tcp
payment-service   Up             0.0.0.0:8082->8082/tcp
order-service     Up             0.0.0.0:18081->8081/tcp
```

- `GET http://localhost:18081/actuator/health` → `{"status":"UP"}`
- `GET http://localhost:8082/actuator/health` → `{"status":"UP"}`
- `GET http://localhost:9411/health` → Zipkin UP,且 storage 顯示
  `ElasticsearchStorage{initialEndpoints=http://elasticsearch:9200, index=zipkin}: UP`
  → **確認 Zipkin 儲存後端確實為 Elasticsearch**
- `GET http://localhost:5601/api/status` → HTTP 200(Kibana 正常)
- ES cluster health:`yellow`(單節點、replicas=0,屬預期狀態)

## 步驟 2:產生流量並驗證 Zipkin 鏈路追蹤

### 流量產生(埠改為 18081)

- `GET /orders/A001` → `{"orderId":"A001","payment":{"status":"PAID","latencyMs":417},"status":"CREATED"}`
- `GET /orders/A002` → PAID,latencyMs=604
- `GET /orders/err001` → HTTP 500(payment-service 依設計拋錯)
- 批次 `B1~B20` 共 20 筆 → 全部成功

### Zipkin API 驗證結果

**服務註冊** — `/api/v2/services` → `["order-service","payment-service"]` ✅

**跨服務 trace(單一 traceId 串起兩服務)** ✅

```
traceId=5ce102a5fbfe6317
├─ order-service   span=get /orders/{id}        306864 µs  (server)
├─ order-service   span=get → /payments/B18     297686 µs  (client,RestTemplate 呼叫)
└─ payment-service span=get /payments/{orderid} 294349 µs  (server)
```
三個 span 共用同一 traceId,證明 Sleuth 的 B3 header 傳遞成功。

**Error trace** ✅ — `traceId=e2b0692fed213163`(err001):
order-service 與 payment-service 的 span 都帶 `error=500` tag,
Zipkin UI 會將此 trace 標紅。

**服務依賴拓撲** ✅ — `/api/v2/dependencies` →

```json
[{"parent":"order-service","child":"payment-service","callCount":23,"errorCount":1}]
```

callCount=23 與 errorCount=1 與實際流量(2 正常 + 1 錯誤 + 20 批次)完全吻合。

> **發現**:Zipkin 使用 Elasticsearch 儲存時,Dependencies 頁面**不會**即時計算,
> 必須另外執行 `openzipkin/zipkin-dependencies` 聚合任務(Spark job)。
> 本次以一次性容器執行後拓撲即出現,已補充至 README。

## 步驟 3:驗證 Elasticsearch 中的 trace 與 log 資料

### Trace 索引 ✅

```
zipkin-span-2026-08-10        docs.count=69   (trace 資料確實存在 ES)
zipkin-dependency-2026-08-10  docs.count=1    (依賴聚合結果)
```

span 文件內容含 `traceId`、`duration`、`localEndpoint.serviceName`、`kind`(CLIENT/SERVER)等欄位。

### Log 索引 — 發現並修正第 4 個問題

| 問題 | 原因 | 修正 |
|---|---|---|
| `poc-logs-*` 索引 0 筆文件,Filebeat 內部日誌大量 `Cannot index event (status=400): dropping event!` | logback `customFields` 輸出字串欄位 `"service"`,與 Filebeat ECS 預設 template 中的 `service` **object** 欄位(`service.name` 等)mapping 衝突,所有事件被 ES 拒絕 | 兩服務 logback-spring.xml 的自訂欄位改名 `service` → `service_name`,重置 log volume、刪除壞索引、重建 Filebeat 容器後重新收取 |

修正後 `poc-logs-2026.08.10` 成功寫入 **64 筆**日誌文件。

### traceId 跨服務關聯(核心驗證)✅

以 orderId=C001 的請求為例,`traceId=ce25f985f0f47023`:

**ES 日誌查詢** `term: traceId=ce25f985f0f47023` → 4 筆,跨兩服務、時間順序正確:

```
03:32:04.472 [  order-service] 收到下單請求 orderId=C001
03:32:04.560 [payment-service] 收到扣款請求 orderId=C001,模擬處理耗時 461ms
03:32:05.025 [payment-service] 扣款成功 orderId=C001
03:32:05.489 [  order-service] payment-service 回應: {orderId=C001, latencyMs=461, status=PAID}
```

**Zipkin 同一 traceId** `/api/v2/trace/ce25f985f0f47023` → 3 個 span,
services = [order-service, payment-service]

→ **同一個 traceId 同時串起 Zipkin trace 與 ES 日誌,Tracing ↔ Logging 交叉關聯成立。**

## 步驟 4:Kibana log correlation

- 以 Saved Objects API 建立 index pattern `poc-logs-*`(time field: `@timestamp`)✅
- 透過 Kibana 以 `traceId : "ce25f985f0f47023"` 過濾 → 命中 4 筆,
  同一請求在 order-service 與 payment-service 的日誌被串在一起 ✅

UI 操作對應:http://localhost:5601 → Discover → 搜尋列輸入 `traceId : "<值>"`。

## 步驟 5:交叉驗證(Zipkin → Kibana 排障動線)

模擬實際排障:在 Zipkin 以 `annotationQuery=error` 找到失敗的 trace
(`traceId=2103a27f2b89b916`,orderId=errC03),複製 traceId 到 Kibana 過濾:

```
 INFO [order-service]   收到下單請求 orderId=errC03
 INFO [payment-service] 收到扣款請求 orderId=errC03,模擬處理耗時 364ms
ERROR [payment-service] 扣款失敗 orderId=errC03
ERROR [order-service]   Servlet.service() ... HttpServerErrorException$InternalServerError: 500 ...
```

→ **從 Zipkin 的 error trace 一鍵切到 Kibana 完整業務日誌(含兩服務的 ERROR),
README 描述的排障動線驗證通過。** ✅
