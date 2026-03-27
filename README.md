# Kafka: SSL, mTLS и ACL

## Состав работы

| Компонент | Описание |
|-----------|----------|
| `docker-compose.yaml` | Кластер Kafka в режиме KRaft, три брокера, Schema Registry и Kafka UI; сервис инициализации ACL `kafka-init`; Spring-клиент `kafka-client`. |
| `scripts/` | `generate-certs.sh` / `generate-certs.ps1` — создают каталог `secrets/` и выпускают CA, брокеры и клиентские JKS. |
| `secrets/` | Появляется после запуска скриптов; сгенерированные `*.jks` / `*.pem` и т.п. в Git не коммитятся (см. `.gitignore`). |
| `kafka-client/` | Spring Boot 3: отдельные keystore для продюсера и консьюмера; в **`spring.kafka.ssl`** заданы truststore и keystore — **AdminClient** (`describeCluster` в `SslRunner`) берёт общий SSL; по умолчанию тот же keystore, что у producer (`SSL_PRODUCER_KEYSTORE` или опционально `SSL_ADMIN_KEYSTORE`). Блок `app.kafka` в `application.yml` (`KafkaClientProperties`: топики, ожидание кластера, `consumer-group-id` → `spring.kafka.consumer.group-id`). |

## Реализация

- На брокерах для слушателей **INTERNAL** и **EXTERNAL** включена обязательная проверка клиентского сертификата (`ssl.client.auth=required`).
- Настроен маппинг principal по `ssl.principal.mapping.rules`: по CN выдаются principals `User:producer`, `User:consumer`, `User:kafka-0` и т.д.
- Super users для инфраструктуры и межброкерного обмена: `admin`, `kafka-0`, `kafka-1`, `kafka-2`, `schema-registry`, `kafka-ui`; для KRaft на PLAINTEXT **CONTROLLER** до готовности authorizer добавлен `User:ANONYMOUS` (см. `docker-compose.yaml`).
- Клиентское приложение использует **разные** keystore: запись — `producer.keystore.jks`, потребление — `consumer.keystore.jks`; для TLS к брокерам с `ssl.client.auth=required` общий SSL (в т.ч. **AdminClient**) должен включать клиентский сертификат — в проекте это тот же материал, что у producer, если не задан отдельный `SSL_ADMIN_KEYSTORE`.
- **Schema Registry (образ `bitnamilegacy/schema-registry:7.6`):** скрипт Bitnami подставляет `kafkastore.ssl.*` только если в каталоге сертификатов лежат файлы с именами **`schema-registry.keystore.jks`** и **`schema-registry.truststore.jks`** (не `ssl.*` / `kafka.*` для этой цели). В compose они смонтированы из `secrets/clients/schema-registry.keystore.jks` и `secrets/kafka.truststore.jks`.

## Требования к запуску

- Docker и Docker Compose v2.
- Для локального запуска Spring (без Docker-образа клиента): JDK 17, Maven 3.9+.
- Для генерации сертификатов на Windows: PowerShell 7+ (`pwsh`), на Linux/macOS — `bash`, `openssl`, `keytool`.

## Порядок запуска

1. **Сгенерировать сертификаты** (один раз перед первым запуском; каталог `secrets/` создаётся скриптом):

   ```bash
   bash scripts/generate-certs.sh
   ```

   или

   ```powershell
   pwsh -File scripts/generate-certs.ps1
   ```

2. **Поднять стек:**

   ```bash
   docker compose up -d --build
   ```

3. **Проверить логи клиента** `kafka-client`:

   ```bash
   docker compose logs -f kafka-client
   ```

   **Ожидаемое поведение:** успешная отправка в `topic-1` и `topic-2`; потребление с `topic-1` через `@KafkaListener`; разовое чтение `topic-2` ручным consumer — ожидаемый отказ ACL (в логах строка уровня INFO про отказ, без успешного чтения).

## Альтернатива: только кластер в Docker, клиент на хосте

1. Шаги 1–2 из предыдущего раздела (сертификаты и `docker compose up`).
2. Остановить или не запускать сервис `kafka-client`, если нужен чистый сценарий с локальным JVM.
3. Из каталога `kafka-client/`:

   ```bash
   mvn spring-boot:run
   ```

   По умолчанию bootstrap: `localhost:9094,9095,9096`; пути к JKS в `application.yml` рассчитаны на расположение `../secrets/...` относительно модуля (после шага генерации сертификатов).

## Переменные окружения сервиса `kafka-client` (в Compose)

| Переменная | Назначение |
|------------|------------|
| `SPRING_KAFKA_BOOTSTRAP_SERVERS` | Список брокеров (в compose — внутренние `kafka-*:9092`). |
| `APP_KAFKA_TOPICS_ONE` | Первый топик (должен совпадать с тем, что создаёт `kafka-init`, и с ACL). |
| `APP_KAFKA_TOPICS_TWO` | Второй топик — то же замечание. |
| `APP_KAFKA_CONSUMER_GROUP_ID` | Группа consumer по умолчанию (`kafka-ssl-client`); должна совпадать с тем, что ожидает ACL для `topic-1`. |
| `APP_KAFKA_CLUSTER_WAIT_TIMEOUT` | Сколько ждать ответа кластера перед сценарием (по умолчанию `60s`; цикл `describeCluster`). |
| `APP_KAFKA_CLUSTER_WAIT_POLL` | Интервал между попытками (по умолчанию `500ms`). |
| `SSL_TRUSTSTORE` | `file:/certs/kafka.truststore.jks` |
| `SSL_PRODUCER_KEYSTORE` | `file:/certs/clients/producer.keystore.jks` (также используется как keystore общего `spring.kafka.ssl` / AdminClient, если не задан `SSL_ADMIN_KEYSTORE`) |
| `SSL_ADMIN_KEYSTORE` | необязательно; если задан — keystore для общего SSL и AdminClient (например `file:/certs/clients/admin.keystore.jks`) |
| `SSL_CONSUMER_KEYSTORE` | `file:/certs/clients/consumer.keystore.jks` |
| `SSL_KEYSTORE_PASSWORD` | пароль хранилищ (совпадает со скриптом генерации и настройками в compose) |

Локально без Docker те же имена топиков задаются через `application.yml` или переменные `APP_KAFKA_TOPICS_ONE` / `APP_KAFKA_TOPICS_TWO`; bootstrap по умолчанию — `localhost:9094,9095,9096` (`SPRING_KAFKA_BOOTSTRAP_SERVERS`). Перед отправкой клиент ждёт доступность кластера (`app.kafka.cluster-wait.*` или `APP_KAFKA_CLUSTER_WAIT_*`). `app.kafka.consumer-group-id` задаёт и `@KafkaListener`, и `spring.kafka.consumer.group-id` через плейсхолдер.

## ACL (сервис `kafka-init`)

- **topic-1:** `User:producer` — Write, Describe; `User:consumer` — Read, Describe, группы `*`.
- **topic-2:** для `User:producer` — Write и Describe; для `User:consumer` **нет** права Read (проверка сценария отказа).
- Дополнительно выданы операции на уровне кластера, необходимые клиенту (Describe, IdempotentWrite и т.п. — см. скрипт в `kafka-init` в `docker-compose.yaml`).

## Безопасность

- Единый пароль **`sercret123`** для **JKS** (truststore/keystore и ключей внутри них): скрипты `generate-certs.*`, брокеры (`KAFKA_CERTIFICATE_PASSWORD`), Schema Registry, Kafka UI, `kafka-init`, Spring-клиент (`SSL_KEYSTORE_PASSWORD`) - только для локальной практики.
- Файлы `*.jks`, `ca.keystore.jks` и прочие TLS-артефакты под `secrets/` не коммитятся.
