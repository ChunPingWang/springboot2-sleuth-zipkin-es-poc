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
