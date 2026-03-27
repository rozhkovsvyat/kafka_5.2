# =============================================================================
# Генерация TLS-материала для Kafka: CA, брокеры kafka-0..2, клиентские keystore.
# Клиенты (CN = principal в ACL): admin, producer, consumer, schema-registry, kafka-ui.
# Пароль хранилищ: переменная CERT_PASSWORD или по умолчанию sercret123 (см. docker-compose).
# Каталог project/secrets/ создаётся при запуске (см. README).
# =============================================================================
$ErrorActionPreference = "Stop"
$Pass = if ($env:CERT_PASSWORD) { $env:CERT_PASSWORD } else { "sercret123" }
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Secrets = Join-Path $Root "secrets"

# --- Подготовка каталога secrets/ ---
Write-Host "Writing to $Secrets"
New-Item -ItemType Directory -Force -Path $Secrets | Out-Null
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue @(
  (Join-Path $Secrets "0"), (Join-Path $Secrets "1"), (Join-Path $Secrets "2"), (Join-Path $Secrets "clients")
)
# Чистая перегенерация: старые CA, truststore и временные csr/crt в корне secrets/
foreach ($name in @("ca.keystore.jks", "kafka.truststore.jks", "ca-cert.pem")) {
  Remove-Item -LiteralPath (Join-Path $Secrets $name) -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -LiteralPath $Secrets -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in ".csr", ".crt" } |
  Remove-Item -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Secrets "0"), (Join-Path $Secrets "1"), (Join-Path $Secrets "2"), (Join-Path $Secrets "clients") | Out-Null
Set-Location $Secrets

# Не называйте параметр $Args — в PowerShell это конфликтует с $args; keytool тогда вызывается без аргументов (видна только справка).
function Invoke-Keytool {
  param([string[]]$KeytoolArguments)
  & keytool @KeytoolArguments
  if ($LASTEXITCODE -ne 0) { throw "keytool failed exit=$LASTEXITCODE : $KeytoolArguments" }
}

# --- CA ---
Write-Host "=== CA ==="
Invoke-Keytool @(
  "-genkeypair", "-alias", "ca", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650",
  "-keystore", "ca.keystore.jks", "-storepass", $Pass, "-keypass", $Pass,
  "-dname", "CN=Kafka-CA,O=Work,L=MSK,C=RU",
  "-ext", "bc:critical,ca:true,pathlen:32"
)
Invoke-Keytool @("-exportcert", "-alias", "ca", "-keystore", "ca.keystore.jks", "-file", "ca-cert.pem", "-storepass", $Pass, "-noprompt")

# --- Truststore (только CA) ---
Write-Host "=== Truststore (только CA) ==="
Invoke-Keytool @("-importcert", "-alias", "ca", "-file", "ca-cert.pem", "-keystore", "kafka.truststore.jks", "-storepass", $Pass, "-noprompt")
Copy-Item "kafka.truststore.jks" "0\kafka.truststore.jks"
Copy-Item "kafka.truststore.jks" "1\kafka.truststore.jks"
Copy-Item "kafka.truststore.jks" "2\kafka.truststore.jks"

# --- Брокеры kafka-0 .. kafka-2 ---
Write-Host "=== Брокеры kafka-0 .. kafka-2 ==="
foreach ($i in 0, 1, 2) {
  $bn = "kafka-$i"
  $ks = Join-Path $i "kafka.keystore.jks"
  $san = "dns:$bn,dns:localhost,dns:kafka-$i,ip:127.0.0.1"
  Invoke-Keytool @(
    "-genkeypair", "-alias", $bn, "-keyalg", "RSA", "-keysize", "2048", "-validity", "825",
    "-keystore", $ks, "-storepass", $Pass, "-keypass", $Pass,
    "-dname", "CN=$bn,O=Kafka,L=MSK,C=RU",
    "-ext", "SAN=$san"
  )
  $csr = Join-Path $i "broker.csr"
  $crt = Join-Path $i "broker.crt"
  Invoke-Keytool @("-certreq", "-alias", $bn, "-keystore", $ks, "-file", $csr, "-storepass", $Pass)
  Invoke-Keytool @(
    "-gencert", "-alias", "ca", "-keystore", "ca.keystore.jks", "-storepass", $Pass,
    "-infile", $csr, "-outfile", $crt, "-validity", "825",
    "-ext", "SAN=$san"
  )
  Invoke-Keytool @("-importcert", "-alias", "ca", "-file", "ca-cert.pem", "-keystore", $ks, "-storepass", $Pass, "-noprompt")
  Invoke-Keytool @("-importcert", "-alias", $bn, "-file", $crt, "-keystore", $ks, "-storepass", $Pass, "-noprompt", "-trustcacerts")
  Remove-Item $csr, $crt -ErrorAction SilentlyContinue
}

# Клиентский keystore: ключ + цепочка, CN совпадает с именем в ssl.principal.mapping.rules / ACL.
function Sign-Client([string]$cn, [string]$outPath) {
  Invoke-Keytool @(
    "-genkeypair", "-alias", $cn, "-keyalg", "RSA", "-keysize", "2048", "-validity", "825",
    "-keystore", $outPath, "-storepass", $Pass, "-keypass", $Pass,
    "-dname", "CN=$cn,O=Kafka,L=MSK,C=RU"
  )
  $csr = Join-Path "clients" "$cn.csr"
  $crt = Join-Path "clients" "$cn.crt"
  Invoke-Keytool @("-certreq", "-alias", $cn, "-keystore", $outPath, "-file", $csr, "-storepass", $Pass)
  Invoke-Keytool @(
    "-gencert", "-alias", "ca", "-keystore", "ca.keystore.jks", "-storepass", $Pass,
    "-infile", $csr, "-outfile", $crt, "-validity", "825"
  )
  Invoke-Keytool @("-importcert", "-alias", "ca", "-file", "ca-cert.pem", "-keystore", $outPath, "-storepass", $Pass, "-noprompt")
  Invoke-Keytool @("-importcert", "-alias", $cn, "-file", $crt, "-keystore", $outPath, "-storepass", $Pass, "-noprompt", "-trustcacerts")
  Remove-Item $csr, $crt -ErrorAction SilentlyContinue
}

Write-Host "=== Клиенты (CN → User:<cn> через ssl.principal.mapping.rules) ==="
Sign-Client "admin" (Join-Path "clients" "admin.keystore.jks")
Sign-Client "producer" (Join-Path "clients" "producer.keystore.jks")
Sign-Client "consumer" (Join-Path "clients" "consumer.keystore.jks")
Sign-Client "schema-registry" (Join-Path "clients" "schema-registry.keystore.jks")
Sign-Client "kafka-ui" (Join-Path "clients" "kafka-ui.keystore.jks")
Copy-Item "kafka.truststore.jks" "clients\kafka.truststore.jks"

Write-Host "=== Готово ==="
$caKeystore = Join-Path $Secrets "ca.keystore.jks"
Write-Host "CA приватный ключ: $caKeystore - не публикуйте."
# Сообщение только ASCII: при запуске из Windows PowerShell 5.1 без UTF-8 BOM кириллица в этой строке ломала разбор кавычек.
Write-Host "Для переноса на другой ПК: kafka.truststore.jks, */kafka.*.jks, clients/*.jks, ca-cert.pem (опционально)."
