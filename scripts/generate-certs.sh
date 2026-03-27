#!/usr/bin/env bash
# =============================================================================
# Генерация TLS-материала для Kafka: CA, брокеры kafka-0..2, клиентские keystore.
# Клиенты (CN = principal в ACL): admin, producer, consumer, schema-registry, kafka-ui.
# Пароль хранилищ: переменная CERT_PASSWORD или по умолчанию sercret123 (см. docker-compose).
# Каталог project/secrets/ создаётся при запуске (см. README).
# =============================================================================
set -euo pipefail

PASS="${CERT_PASSWORD:-sercret123}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/secrets"

# --- Подготовка каталога secrets/ ---
echo "Writing to $SECRETS"
mkdir -p "$SECRETS"
rm -rf "${SECRETS}/0" "${SECRETS}/1" "${SECRETS}/2" "${SECRETS}/clients"

cd "$SECRETS"
# Чистая перегенерация: старые CA, truststore и временные csr/crt в корне secrets/
rm -f ca.keystore.jks kafka.truststore.jks ca-cert.pem
rm -f ./*.csr ./*.crt 2>/dev/null || true

mkdir -p "0" "1" "2" "clients"

# --- CA ---
echo "=== CA ==="
keytool -genkeypair -alias ca -keyalg RSA -keysize 2048 -validity 3650 \
  -keystore ca.keystore.jks -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=Kafka-CA,O=Work,L=MSK,C=RU" \
  -ext "bc:critical,ca:true,pathlen:32"

keytool -exportcert -alias ca -keystore ca.keystore.jks -file ca-cert.pem -storepass "$PASS" -noprompt

# --- Truststore (только CA) ---
echo "=== Truststore (только CA) ==="
keytool -importcert -alias ca -file ca-cert.pem -keystore kafka.truststore.jks -storepass "$PASS" -noprompt

for i in 0 1 2; do
  cp kafka.truststore.jks "$i/kafka.truststore.jks"
done

# --- Брокеры kafka-0 .. kafka-2 ---
echo "=== Брокеры kafka-0 .. kafka-2 ==="
for i in 0 1 2; do
  BN="kafka-$i"
  KS="$i/kafka.keystore.jks"
  SAN="dns:${BN},dns:localhost,dns:kafka-${i},ip:127.0.0.1"
  keytool -genkeypair -alias "$BN" -keyalg RSA -keysize 2048 -validity 825 \
    -keystore "$KS" -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=${BN},O=Kafka,L=MSK,C=RU" \
    -ext "SAN=$SAN"

  keytool -certreq -alias "$BN" -keystore "$KS" -file "$i/broker.csr" -storepass "$PASS"

  keytool -gencert -alias ca -keystore ca.keystore.jks -storepass "$PASS" \
    -infile "$i/broker.csr" -outfile "$i/broker.crt" -validity 825 \
    -ext "SAN=$SAN"

  keytool -importcert -alias ca -file ca-cert.pem -keystore "$KS" -storepass "$PASS" -noprompt
  keytool -importcert -alias "$BN" -file "$i/broker.crt" -keystore "$KS" -storepass "$PASS" -noprompt -trustcacerts

  rm -f "$i/broker.csr" "$i/broker.crt"
done

# Клиентский keystore: ключ + цепочка, CN совпадает с именем в ssl.principal.mapping.rules / ACL.
sign_client() {
  local cn="$1"
  local out="$2"
  keytool -genkeypair -alias "$cn" -keyalg RSA -keysize 2048 -validity 825 \
    -keystore "$out" -storepass "$PASS" -keypass "$PASS" \
    -dname "CN=${cn},O=Kafka,L=MSK,C=RU"

  keytool -certreq -alias "$cn" -keystore "$out" -file "clients/${cn}.csr" -storepass "$PASS"

  keytool -gencert -alias ca -keystore ca.keystore.jks -storepass "$PASS" \
    -infile "clients/${cn}.csr" -outfile "clients/${cn}.crt" -validity 825

  keytool -importcert -alias ca -file ca-cert.pem -keystore "$out" -storepass "$PASS" -noprompt
  keytool -importcert -alias "$cn" -file "clients/${cn}.crt" -keystore "$out" -storepass "$PASS" -noprompt -trustcacerts

  rm -f "clients/${cn}.csr" "clients/${cn}.crt"
}

echo "=== Клиенты (CN → User:<cn> через ssl.principal.mapping.rules) ==="
sign_client admin "clients/admin.keystore.jks"
sign_client producer "clients/producer.keystore.jks"
sign_client consumer "clients/consumer.keystore.jks"
sign_client schema-registry "clients/schema-registry.keystore.jks"
sign_client kafka-ui "clients/kafka-ui.keystore.jks"

cp kafka.truststore.jks clients/

echo "=== Готово ==="
echo "CA приватный ключ: $SECRETS/ca.keystore.jks — не публикуйте."
echo "Для переноса на другой ПК: kafka.truststore.jks, */kafka.*.jks, clients/*.jks, ca-cert.pem (опционально)."
