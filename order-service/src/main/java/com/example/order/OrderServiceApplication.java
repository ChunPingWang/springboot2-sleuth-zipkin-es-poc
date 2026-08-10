package com.example.order;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import java.util.HashMap;
import java.util.Map;

@SpringBootApplication
public class OrderServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrderServiceApplication.class, args);
    }

    /**
     * 重點:RestTemplate 必須以 @Bean 方式註冊,
     * Sleuth 才能自動加上攔截器,將 B3 headers
     * (X-B3-TraceId / X-B3-SpanId ...) 傳遞給下游服務。
     * 若直接 new RestTemplate() 則 trace context 不會傳遞!
     */
    @Bean
    public RestTemplate restTemplate(RestTemplateBuilder builder) {
        return builder.build();
    }
}

@RestController
class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    private final RestTemplate restTemplate;
    private final String paymentServiceUrl;

    OrderController(RestTemplate restTemplate,
                    @Value("${payment.service.url}") String paymentServiceUrl) {
        this.restTemplate = restTemplate;
        this.paymentServiceUrl = paymentServiceUrl;
    }

    /**
     * 模擬下單:order-service 收到請求後呼叫 payment-service 扣款。
     * Sleuth 會:
     *  1. 產生 traceId(整條鏈路共用)與 spanId
     *  2. 注入 MDC → log 自動帶 traceId
     *  3. 透過 RestTemplate 攔截器把 trace context 傳給 payment-service
     */
    @GetMapping("/orders/{id}")
    public Map<String, Object> createOrder(@PathVariable String id) {
        log.info("收到下單請求 orderId={}", id);

        @SuppressWarnings("unchecked")
        Map<String, Object> paymentResult = restTemplate.getForObject(
                paymentServiceUrl + "/payments/" + id, Map.class);

        log.info("payment-service 回應: {}", paymentResult);

        Map<String, Object> response = new HashMap<>();
        response.put("orderId", id);
        response.put("status", "CREATED");
        response.put("payment", paymentResult);
        return response;
    }
}
