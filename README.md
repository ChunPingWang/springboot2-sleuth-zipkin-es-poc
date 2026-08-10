# Spring Boot 2 微服務鏈路追蹤 PoC

**Sleuth + Zipkin(儲存後端 = Elasticsearch)+ Kibana + Filebeat log correlation**

## 架構

```
                    HTTP GET /orders/{id}
  使用者 ──────────> order-service (8081)
                          │
                          │ RestTemplate(Sleuth 自動注入 B3 headers)
                          ▼
                    payment-service (8082)

  兩服務的 span  ──HTTP──> Zipkin (9411) ──> Elasticsearch (zipkin-span-*)
  兩服務的 JSON log ──Filebeat──> Elasticsearch (poc-logs-*)

  Zipkin UI  : 瀑布圖 / 服務依賴拓撲(讀 ES)
  Kibana     : 以 traceId 過濾跨服務日誌(log correlation)
```

## 系統需求

- Docker + Docker Compose
- 記憶體至少 4GB 可用(ES 1GB heap + 其餘容器)

## 啟動

```bash
docker compose up -d --build
# 首次 build 需下載 Maven 依賴,約 3~5 分鐘
docker compose ps          # 確認全部 healthy / running
```

## 驗證步驟

### 1. 產生流量

```bash
# 正常請求(產生跨兩服務的 trace)
curl http://localhost:8081/orders/A001
curl http://localhost:8081/orders/A002

# 錯誤請求(orderId 以 err 開頭 → payment-service 回 500)
curl http://localhost:8081/orders/err001

# 批次打流量,方便看延遲分布
for i in $(seq 1 20); do curl -s http://localhost:8081/orders/B$i > /dev/null; done
```

### 2. Zipkin UI 看鏈路(http://localhost:9411)

- 點 **RUN QUERY** → 可看到每筆 trace,展開後是瀑布圖:
  `order-service` 的 span 包含 `payment-service` 的子 span,可見各段耗時
- err 開頭的請求會標紅,點入可看到 error tag
- **Dependencies** 頁籤 → 服務依賴拓撲圖(order → payment)

> 注意:storage 為 Elasticsearch 時,Dependencies 需另跑聚合任務才有資料:
> ```bash
> docker run --rm --network sleuth-zipkin-es-poc_default \
>   -e STORAGE_TYPE=elasticsearch -e ES_HOSTS=http://elasticsearch:9200 -e ES_INDEX=zipkin \
>   openzipkin/zipkin-dependencies:2.7
> # 正式環境建議以 cron 每日執行
> ```

### 3. 確認 trace 資料真的存在 Elasticsearch

```bash
curl 'http://localhost:9200/_cat/indices/zipkin*?v'
# 應看到 zipkin-span-yyyy-MM-dd 索引

curl 'http://localhost:9200/zipkin-span-*/_search?size=1&pretty'
```

### 4. Kibana log correlation(http://localhost:5601)

1. **Stack Management → Index Patterns** → 建立 `poc-logs-*`(time field: `@timestamp`)
2. **Discover** → 任選一筆 log,複製其 `traceId` 欄位值
3. 搜尋列輸入 `traceId : "<剛複製的值>"`
   → 同一請求在 **order-service 與 payment-service 的所有日誌**被串在一起,
   這就是跨服務的請求軌跡追查

### 5. 交叉驗證(Tracing ↔ Logging 關聯)

在 Zipkin 找一筆慢的 trace,複製其 trace id,到 Kibana 用同一 id 過濾——
可以看到該請求的完整業務日誌,這是排障時最實用的動線。

## 關鍵設定說明

| 檔案 | 重點 |
|---|---|
| `*/pom.xml` | `spring-cloud-starter-sleuth`(產生/傳遞 traceId)+ `spring-cloud-sleuth-zipkin`(上報 span) |
| `*/application.yml` | `sampler.probability: 1.0`(PoC 全採樣)、`propagation.type: B3` |
| `OrderServiceApplication.java` | **RestTemplate 必須註冊為 @Bean**,Sleuth 才會加攔截器傳遞 trace context |
| `logback-spring.xml` | Console pattern 帶 `%X{traceId}`;JSON appender 讓 traceId 成為 ES 可查欄位 |
| `docker-compose.yml` | Zipkin `STORAGE_TYPE=elasticsearch` → trace 存進 ES |
| `filebeat/filebeat.yml` | `json.keys_under_root: true` 讓 traceId 直接成為文件根欄位 |

## 測試結果

執行 `./e2e-test.sh`(端對端自動化測試,2026-08-10,macOS Apple Silicon + Podman):

| # | 測試項目 | 結果 |
|---|---|---|
| T1 | order-service `/actuator/health` = UP | ✅ PASS |
| T2 | payment-service `/actuator/health` = UP | ✅ PASS |
| T3 | Zipkin health = UP 且 storage 為 Elasticsearch | ✅ PASS |
| T4 | Elasticsearch cluster health = green/yellow | ✅ PASS |
| T5 | Kibana `/api/status` = 200 | ✅ PASS |
| T6 | `GET /orders/{id}` 回應 CREATED + PAID(跨服務呼叫成功) | ✅ PASS |
| T7 | `GET /orders/err*` 回應 HTTP 500(錯誤情境如設計) | ✅ PASS |
| T8 | Zipkin 單一 traceId 的 trace 跨 order/payment 兩服務 | ✅ PASS |
| T9 | Zipkin error trace 帶 error tag | ✅ PASS |
| T10 | 依賴拓撲 order-service → payment-service 存在 | ✅ PASS |
| T11 | ES 索引有資料(zipkin-span-* 99 筆、poc-logs-* 72 筆) | ✅ PASS |
| T12 | ES 以 traceId 查日誌,涵蓋兩個服務(log correlation) | ✅ PASS |
| T13 | Kibana 以 traceId 過濾命中跨服務日誌 4 筆 | ✅ PASS |

**合計:13 / 13 全數通過**。完整驗證過程(含發現並修正的 4 個問題)見 [VALIDATION.md](VALIDATION.md)。

> 注意:本環境 order-service 對外埠為 **18081**(主機 8081 被既有服務占用),
> 測試腳本已使用 18081;若你的環境 8081 可用,可將 docker-compose.yml 與腳本改回。

## 生產環境調整建議

1. **採樣率**:`sampler.probability` 改 `0.1`(10%),或評估 tail-based sampling
2. **上報解耦**:`spring.zipkin.sender.type` 改 `kafka`,避免 Zipkin 短暫故障影響應用
3. **索引生命週期**:對 `zipkin-span-*` 與 `poc-logs-*` 設定 ILM(trace 建議保留 7~14 天)
4. **ES 安全性**:開啟 `xpack.security`,Zipkin/Filebeat 補上帳密
5. **資源配置**:`ES_INDEX_SHARDS`/`REPLICAS` 依叢集規模調整(PoC 為 1/0)
6. **升級路徑**:Sleuth 在 Spring Boot 3 已由 Micrometer Tracing 取代;
   若有升級計畫,propagation 可先改 `W3C` 與 OTel 生態接軌

## 清理

```bash
docker compose down -v    # -v 一併刪除 ES 資料與 log volume
```
