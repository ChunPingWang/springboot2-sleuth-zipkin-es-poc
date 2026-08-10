#!/bin/zsh
# 端對端測試:每項輸出 PASS/FAIL
PASS=0; FAIL=0
check() { # $1=名稱 $2=結果(0/1)
  if [ "$2" -eq 0 ]; then echo "PASS | $1"; PASS=$((PASS+1)); else echo "FAIL | $1"; FAIL=$((FAIL+1)); fi
}

# T1 健康檢查
curl -sf http://localhost:18081/actuator/health | grep -q '"UP"'; check "T1 order-service /actuator/health = UP" $?
curl -sf http://localhost:8082/actuator/health  | grep -q '"UP"'; check "T2 payment-service /actuator/health = UP" $?
curl -sf http://localhost:9411/health | grep -q 'ElasticsearchStorage'; check "T3 Zipkin health = UP 且 storage 為 Elasticsearch" $?
curl -sf http://localhost:9200/_cluster/health | grep -Eq '"status":"(green|yellow)"'; check "T4 Elasticsearch cluster health = green/yellow" $?
[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5601/api/status)" = "200" ]; check "T5 Kibana /api/status = 200" $?

# T6 正常下單:回應含 PAID
OID="T$(date +%s)"
RESP=$(curl -s http://localhost:18081/orders/$OID)
echo "$RESP" | grep -q '"status":"PAID"' && echo "$RESP" | grep -q '"status":"CREATED"'; check "T6 GET /orders/$OID 回應 CREATED+PAID" $?

# T7 錯誤請求回 500
[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18081/orders/err$OID)" = "500" ]; check "T7 GET /orders/err$OID 回應 HTTP 500" $?

sleep 12   # 等 span 上報與 Filebeat 收取

# T8 Zipkin:此請求的 trace 跨兩服務
TID=$(curl -s "http://localhost:9411/api/v2/traces?serviceName=order-service&annotationQuery=http.path%3D/orders/$OID&limit=1" \
  | python3 -c "import json,sys; t=json.load(sys.stdin); print(t[0][0]['traceId'] if t else '')")
SVCS=$(curl -s "http://localhost:9411/api/v2/trace/$TID" \
  | python3 -c "import json,sys; s=json.load(sys.stdin); print(','.join(sorted({x['localEndpoint']['serviceName'] for x in s})))" 2>/dev/null)
[ "$SVCS" = "order-service,payment-service" ]; check "T8 Zipkin trace($TID) 跨兩服務" $?

# T9 error trace 帶 error tag
curl -s "http://localhost:9411/api/v2/traces?serviceName=payment-service&annotationQuery=error&limit=1" \
  | grep -q '"error"'; check "T9 Zipkin error trace 帶 error tag" $?

# T10 依賴拓撲
curl -s "http://localhost:9411/api/v2/dependencies?endTs=$(($(date +%s)*1000))&lookback=86400000" \
  | grep -q '"parent":"order-service","child":"payment-service"'; check "T10 依賴拓撲 order→payment 存在" $?

# T11 ES 索引有資料
SPANS=$(curl -s 'http://localhost:9200/zipkin-span-*/_count' | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
LOGS=$(curl -s 'http://localhost:9200/poc-logs-*/_count' | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
[ "$SPANS" -gt 0 ] && [ "$LOGS" -gt 0 ]; check "T11 ES 索引有資料(spans=$SPANS, logs=$LOGS)" $?

# T12 同 traceId 的日誌跨兩服務(log correlation)
NSVC=$(curl -s 'http://localhost:9200/poc-logs-*/_search' -H 'Content-Type: application/json' \
  -d "{\"query\":{\"term\":{\"traceId\":\"$TID\"}},\"size\":20,\"_source\":[\"service_name\"]}" \
  | python3 -c "import json,sys; h=json.load(sys.stdin)['hits']['hits']; print(len({x['_source'].get('service_name') for x in h}))")
[ "$NSVC" = "2" ]; check "T12 ES 以 traceId=$TID 查日誌,涵蓋 2 個服務" $?

# T13 Kibana 端 traceId 過濾
KHITS=$(curl -s -XPOST "http://localhost:5601/api/console/proxy?path=poc-logs-*%2F_search&method=POST" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d "{\"query\":{\"term\":{\"traceId\":\"$TID\"}},\"size\":20}" \
  | python3 -c "import json,sys; print(len(json.load(sys.stdin)['hits']['hits']))")
[ "$KHITS" -ge 2 ]; check "T13 Kibana 以 traceId 過濾命中 $KHITS 筆跨服務日誌" $?

echo "----"
echo "RESULT | PASS=$PASS FAIL=$FAIL"
