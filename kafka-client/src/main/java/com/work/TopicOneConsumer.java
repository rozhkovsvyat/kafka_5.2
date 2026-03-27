package com.work;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

/** Слушатель первого топика; настройки — {@link KafkaClientProperties}. */
@Component
public class TopicOneConsumer {

  private static final Logger log = LoggerFactory.getLogger(TopicOneConsumer.class);

  private final String topicOne;
  private final String consumerGroupId;

  public TopicOneConsumer(KafkaClientProperties appKafka) {
    this.topicOne = appKafka.topics().one();
    this.consumerGroupId = appKafka.consumerGroupId();
  }

  public String getTopicOne() {
    return topicOne;
  }

  public String getConsumerGroupId() {
    return consumerGroupId;
  }

  @KafkaListener(topics = "#{__listener.topicOne}", groupId = "#{__listener.consumerGroupId}")
  public void onMessage(String payload) {
    log.info("[{}] получено сообщение: {}", topicOne, payload);
  }
}
