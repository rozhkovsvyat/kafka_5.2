package com.work;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.apache.kafka.clients.admin.AdminClient;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.errors.AuthorizationException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.autoconfigure.kafka.KafkaProperties;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

/**
 * Стартовый сценарий: отправка в оба топика из {@link KafkaClientProperties#topics()}, затем разовый poll второго топика ручным consumer.
 * Ожидание кластера — {@link KafkaClientProperties#clusterWait()}.
 * Второй топик не через {@code @KafkaListener} — при отказе ACL поведение контейнера слушателя было бы другим.
 */
@Component
public class SslRunner implements ApplicationRunner {

  private static final Logger log = LoggerFactory.getLogger(SslRunner.class);

  private static final int DESCRIBE_CLUSTER_TIMEOUT_SEC = 5;
  private static final int SEND_TIMEOUT_SEC = 60;
  private static final int TOPIC2_POLL_SEC = 8;

  /** Разовый assign/poll только партиция 0 (остальные не читаем). */
  private static final int TOPIC2_PARTITION = 0;

  private final KafkaTemplate<String, String> kafkaTemplate;
  private final KafkaProperties kafkaProperties;
  private final KafkaClientProperties appKafka;

  public SslRunner(
      KafkaTemplate<String, String> kafkaTemplate,
      KafkaProperties kafkaProperties,
      KafkaClientProperties appKafka) {
    this.kafkaTemplate = kafkaTemplate;
    this.kafkaProperties = kafkaProperties;
    this.appKafka = appKafka;
  }

  @Async
  @Override
  public void run(ApplicationArguments args) {
    var wait = appKafka.clusterWait();
    if (!waitUntilClusterReady(wait.timeout(), wait.pollInterval())) {
      return;
    }
    publishMessages();
    tryReadTopicTwo();
  }

  /**
   * Повторяет {@link AdminClient#describeCluster()} до успеха или истечения таймаута (вместо фиксированного sleep).
   */
  private boolean waitUntilClusterReady(Duration timeout, Duration pollInterval) {
    long pollMs = Math.max(100L, pollInterval.toMillis());
    long deadlineNanos = System.nanoTime() + timeout.toNanos();
    Map<String, Object> adminProps = kafkaProperties.buildAdminProperties(null);

    while (System.nanoTime() < deadlineNanos) {
      try (AdminClient admin = AdminClient.create(adminProps)) {
        admin.describeCluster().clusterId().get(DESCRIBE_CLUSTER_TIMEOUT_SEC, TimeUnit.SECONDS);
        log.info("Kafka: кластер доступен (describeCluster)");
        return true;
      } catch (Exception e) {
        if (Thread.currentThread().isInterrupted()) {
          Thread.currentThread().interrupt();
          return false;
        }
        log.debug("Kafka ещё недоступен: {}", e.toString());
        if (sleepInterrupted(pollMs)) {
          return false;
        }
      }
    }

    log.warn("Kafka: нет ответа кластера за {}", timeout);
    return false;
  }

  private static boolean sleepInterrupted(long millis) {
    try {
      Thread.sleep(millis);
      return false;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return true;
    }
  }

  private void publishMessages() {
    var topics = appKafka.topics();
    try {
      String suffix = String.valueOf(System.currentTimeMillis());
      kafkaTemplate.send(topics.one(), "hello-" + topics.one() + "-" + suffix).get(SEND_TIMEOUT_SEC, TimeUnit.SECONDS);
      log.info("Producer: отправлено в {}", topics.one());

      kafkaTemplate.send(topics.two(), "hello-" + topics.two() + "-" + suffix).get(SEND_TIMEOUT_SEC, TimeUnit.SECONDS);
      log.info("Producer: отправлено в {}", topics.two());
    } catch (Exception e) {
      log.error("Producer: ошибка отправки", e);
    }
  }

  /**
   * Ожидается {@link AuthorizationException}: у consumer (CN=consumer) нет Read на втором топике.
   */
  private void tryReadTopicTwo() {
    var topics = appKafka.topics();
    Map<String, Object> props = consumerPropsForTopicTwo();
    TopicPartition tp = new TopicPartition(topics.two(), TOPIC2_PARTITION);
    try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props)) {
      consumer.assign(List.of(tp));
      consumer.seekToBeginning(List.of(tp));
      ConsumerRecords<String, String> records = consumer.poll(Duration.ofSeconds(TOPIC2_POLL_SEC));
      if (!records.isEmpty()) {
        log.warn("[{}] неожиданно получены записи ({} шт.) — проверьте ACL", topics.two(), records.count());
        records.forEach(r -> log.info("  partition={} offset={} value={}", r.partition(), r.offset(), r.value()));
      } else {
        log.info("[{}] poll без записей (пустой топик или смещения)", topics.two());
      }
    } catch (AuthorizationException e) {
      log.info("[{}] ожидаемый отказ ACL при чтении: {}", topics.two(), e.getMessage());
    } catch (Exception e) {
      log.warn("[{}] ошибка при разовом чтении: {}", topics.two(), e.toString());
    }
  }

  private Map<String, Object> consumerPropsForTopicTwo() {
    Map<String, Object> props = kafkaProperties.buildConsumerProperties(null);
    props.put(ConsumerConfig.GROUP_ID_CONFIG, "topic2-consumer-" + UUID.randomUUID());
    props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
    props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
    props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
    props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class);
    return props;
  }
}
