package com.example.payment;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.http.HttpStatus;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@SpringBootApplication
public class PaymentServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(PaymentServiceApplication.class, args);
    }
}

@RestController
class PaymentController {

    private static final Logger log = LoggerFactory.getLogger(PaymentController.class);

    /**
     * 模擬扣款:
     *  - 隨機延遲 50~800ms → Zipkin 瀑布圖可觀察到 span 耗時差異
     *  - orderId 以 "err" 開頭時回 500 → 觀察 Zipkin 標紅的 error trace
     * 注意:此處 log 的 traceId 與 order-service 相同(由 B3 header 傳入)。
     */
    @GetMapping("/payments/{orderId}")
    public Map<String, Object> pay(@PathVariable String orderId) throws InterruptedException {
        long latency = ThreadLocalRandom.current().nextLong(50, 800);
        log.info("收到扣款請求 orderId={},模擬處理耗時 {}ms", orderId, latency);
        Thread.sleep(latency);

        if (orderId.startsWith("err")) {
            log.error("扣款失敗 orderId={}", orderId);
            throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "payment failed");
        }

        log.info("扣款成功 orderId={}", orderId);
        Map<String, Object> result = new HashMap<>();
        result.put("orderId", orderId);
        result.put("status", "PAID");
        result.put("latencyMs", latency);
        return result;
    }
}
