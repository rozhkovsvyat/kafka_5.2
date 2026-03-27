package com.work;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.kafka")
public record KafkaClientProperties(
    Topics topics, ClusterWait clusterWait, String consumerGroupId) {

  public record Topics(String one, String two) {}

  public record ClusterWait(Duration timeout, Duration pollInterval) {}
}
