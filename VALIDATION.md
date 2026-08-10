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
