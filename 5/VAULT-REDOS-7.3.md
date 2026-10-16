# Vault на РЕД ОС 7.3 для испытания 5

Команды выполняются на двух машинах:

| Машина | Что на ней выполняется |
|---|---|
| Сервер Vault, РЕД ОС 7.3 | Установка Vault, запуск dev-сервера, настройка секрета и Kubernetes-аутентификации |
| Рабочая машина | `kubectl`, подключение Deckhouse к Vault и три скрипта пункта 5 |

На сервере Vault `kubectl` не требуется. API Kubernetes доступен с него через
**HTTPS Ingress Deckhouse**. Репозитории РЕД ОС и сеть уже настроены.
Для передачи файлов ниже используется `scp`; оба терминала Vault и SSH-подключение
должны использовать одну учётную запись сервера.

Режим `-dev` хранит данные в памяти до остановки процесса. `-dev-tls` включает
HTTPS, `-log-level=debug` — подробный журнал. Для испытания используются
искусственные данные. [Параметры сервера Vault](https://developer.hashicorp.com/vault/docs/commands/server).

## 1. Сервер Vault: установка и запуск, терминал 1

Установите актуальный пакет из уже подключённых репозиториев. Команда upgrade
обновит Vault, если на сервере уже установлен более старый пакет.

```bash
set -euo pipefail
sudo dnf install -y vault jq curl
sudo dnf upgrade -y vault

umask 077
export VAULT_IP=192.0.2.10
export VAULT_TEST_DIR="$HOME/pmi-5-vault"
mkdir "$VAULT_TEST_DIR"
mkdir "$VAULT_TEST_DIR/tls"
printf '%s\n' "$VAULT_IP" > "$VAULT_TEST_DIR/vault-ip"

unset VAULT_NAMESPACE VAULT_SKIP_VERIFY VAULT_TOKEN VAULT_DEV_ROOT_TOKEN_ID
vault server -dev -dev-tls \
  -dev-listen-address="$VAULT_IP:8200" \
  -dev-tls-san="$VAULT_IP" \
  -dev-tls-cert-dir="$VAULT_TEST_DIR/tls" \
  -dev-no-store-token \
  -log-level=debug
```

Замените `192.0.2.10` реальным IP сервера Vault, доступным с узлов/Pod кластера.
Оставьте процесс работающим. Vault сам инициализируется и распечатывается,
создаёт TLS-сертификат с указанным IP. Показанный `Root Token` понадобится
в терминале 2 этого сервера. Веб-интерфейс: `https://IP_VAULT:8200/ui/`.
[Dev-сервер с TLS](https://developer.hashicorp.com/vault/tutorials/get-started/setup).

## 2. Рабочая машина: подготовка файлов для Kubernetes-аутентификации

На рабочей машине должны быть `kubectl`, `jq`, `scp`, административный kubeconfig
**с адресом API через Ingress** и каталог `5` комплекта.
Укажите реальную SSH-учётную запись сервера вместо `user@vault-server`.

```bash
set -euo pipefail
cd /путь/к/комплекту/5
umask 077
export VAULT_TRANSFER_DIR="$PWD/pmi-5-vault"
export VAULT_SSH=user@vault-server
mkdir "$VAULT_TRANSFER_DIR"

kubectl config current-context
KUBERNETES_API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "API Kubernetes через Ingress: $KUBERNETES_API"
printf '%s\n' "$KUBERNETES_API" > "$VAULT_TRANSFER_DIR/kubernetes-api"

INSECURE_TLS=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}')
if [ "$INSECURE_TLS" = true ]; then
  echo "ОШИБКА: kubeconfig отключает проверку TLS. Для Vault нужен доверенный CA сертификата Ingress."
  exit 1
fi
API_CA_DATA=$(kubectl config view --minify --flatten --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
printf '%s' "$API_CA_DATA" | base64 --decode > "$VAULT_TRANSFER_DIR/kubernetes-ca.pem"

kubectl create namespace pmi-5-vault
kubectl -n pmi-5-vault create serviceaccount reviewer
kubectl create clusterrolebinding pmi-5-vault-reviewer \
  --clusterrole=system:auth-delegator \
  --serviceaccount=pmi-5-vault:reviewer
kubectl -n pmi-5-vault create token reviewer --duration=4h > "$VAULT_TRANSFER_DIR/reviewer.jwt"

scp -p "$VAULT_TRANSFER_DIR/kubernetes-api" \
  "$VAULT_TRANSFER_DIR/kubernetes-ca.pem" \
  "$VAULT_TRANSFER_DIR/reviewer.jwt" \
  "$VAULT_SSH:pmi-5-vault/"
scp "$VAULT_SSH:pmi-5-vault/vault-ip" "$VAULT_TRANSFER_DIR/vault-ip"
scp "$VAULT_SSH:pmi-5-vault/tls/vault-ca.pem" "$VAULT_TRANSFER_DIR/vault-ca.pem"
```

Выведенный URL должен выглядеть как `https://api.ИМЯ_КЛАСТЕРА:443` — имя
опубликованного Kubernetes API. Если текущий kubeconfig содержит прямой адрес
master-узла или локального прокси, сначала выберите kubeconfig для API через Ingress.
На сервере Vault это имя должно разрешаться в доступный VIP.
Используйте DNS-имя из сертификата Ingress в URL, чтобы сохранить корректные SNI
и проверку сертификата при подключении через VIP.

CA берётся из kubeconfig **для этого Ingress**, а не из `kube-root-ca.crt` кластера:
TLS здесь завершается на Ingress, у него может быть другой сертификат.
Если kubeconfig использует системное доверие к публичному CA, файл CA будет пустым;
в следующем шаге будет использован системный набор CA РЕД ОС.
[Публикация API Deckhouse](https://deckhouse.io/modules/user-authn/v1.73/configuration.html).

На сервер передаются короткоживущий токен reviewer и открытые данные соединения.
Административный kubeconfig остаётся на рабочей машине. Учётная запись приложения
`pmi-5/reader` создаётся позднее скриптом `01-prepare.sh`.

## 3. Сервер Vault: настройка хранилища, терминал 2

Откройте второй терминал сервера под той же учётной записью, что в шаге 1:

```bash
set -euo pipefail
umask 077
export VAULT_TEST_DIR="$HOME/pmi-5-vault"
VAULT_IP=$(cat "$VAULT_TEST_DIR/vault-ip")
export VAULT_ADDR="https://$VAULT_IP:8200"
export VAULT_CACERT="$VAULT_TEST_DIR/tls/vault-ca.pem"
unset VAULT_NAMESPACE VAULT_SKIP_VERIFY
read -rsp 'Введите Root Token из терминала 1: ' VAULT_TOKEN
echo
export VAULT_TOKEN
vault status
vault audit enable -path=pmi-5-audit file file_path="$VAULT_TEST_DIR/audit.jsonl"

vault secrets enable -path=pmi -version=2 kv
vault kv put pmi/dkp-acceptance marker=pmi-value-1
vault kv get -field=marker pmi/dkp-acceptance
vault policy write pmi-5-read - <<'HCL'
path "pmi/data/dkp-acceptance" {
  capabilities = ["read"]
}
HCL
```

Ожидается `Initialized=true`, `Sealed=false` и маркер `pmi-value-1`.
Аудит API Vault сохраняется в `audit.jsonl`; сообщения debug остаются в терминале 1.
В CLI путь секрета — `pmi/dkp-acceptance`, в API KV v2 и политике —
`pmi/data/dkp-acceptance`. [KV v2](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2),
[файловый аудит](https://developer.hashicorp.com/vault/docs/audit/file).

## 4. Сервер Vault, терминал 2: TokenReview через Ingress

Проверяем реальный запрос TokenReview с токеном reviewer. Это одновременно
проверит TLS Ingress, передачу заголовка Authorization и права учётной записи.

```bash
KUBERNETES_API=$(cat "$VAULT_TEST_DIR/kubernetes-api")
if [ ! -s "$VAULT_TEST_DIR/kubernetes-ca.pem" ]; then
  cp /etc/pki/tls/certs/ca-bundle.crt "$VAULT_TEST_DIR/kubernetes-ca.pem"
fi
REVIEWER_JWT=$(cat "$VAULT_TEST_DIR/reviewer.jwt")
printf 'Authorization: Bearer %s\n' "$REVIEWER_JWT" > "$VAULT_TEST_DIR/reviewer-header"
unset REVIEWER_JWT
jq -n --rawfile jwt "$VAULT_TEST_DIR/reviewer.jwt" '
{apiVersion: "authentication.k8s.io/v1", kind: "TokenReview",
 spec: {token: ($jwt | rtrimstr("\n"))}}
' > "$VAULT_TEST_DIR/tokenreview-request.json"

curl --fail --silent --show-error --max-time 15 \
  --cacert "$VAULT_TEST_DIR/kubernetes-ca.pem" \
  --header @"$VAULT_TEST_DIR/reviewer-header" \
  --header 'Content-Type: application/json' \
  --data-binary @"$VAULT_TEST_DIR/tokenreview-request.json" \
  "$KUBERNETES_API/apis/authentication.k8s.io/v1/tokenreviews" \
  > "$VAULT_TEST_DIR/tokenreview-response.json"
jq '.status' "$VAULT_TEST_DIR/tokenreview-response.json"
AUTHENTICATED=$(jq -r '.status.authenticated' "$VAULT_TEST_DIR/tokenreview-response.json")
echo "Токен reviewer принят: $AUTHENTICATED"
if [ "$AUTHENTICATED" != true ]; then
  echo "ОШИБКА: проверка токена через опубликованный Kubernetes API не прошла."
  exit 1
fi

vault auth enable -path=pmi-5-kubernetes kubernetes
vault write auth/pmi-5-kubernetes/config \
  kubernetes_host="$KUBERNETES_API" \
  kubernetes_ca_cert=@"$VAULT_TEST_DIR/kubernetes-ca.pem" \
  token_reviewer_jwt=@"$VAULT_TEST_DIR/reviewer.jwt"
vault write auth/pmi-5-kubernetes/role/pmi-5-reader \
  bound_service_account_names=reader \
  bound_service_account_namespaces=pmi-5 \
  token_policies=pmi-5-read \
  token_no_default_policy=true \
  token_ttl=10m \
  token_max_ttl=30m
vault read auth/pmi-5-kubernetes/role/pmi-5-reader
```

Ожидается `authenticated=true` и имя `system:serviceaccount:pmi-5-vault:reviewer`.
Токен reviewer запрошен на четыре часа; сервер API может сократить срок.
При истечении выпустите новый токен на рабочей машине, передайте файл на Vault
и повторите `vault write auth/pmi-5-kubernetes/config ...`.
[Аутентификация Kubernetes](https://developer.hashicorp.com/vault/docs/auth/kubernetes),
[API настройки роли](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes).

## 5. Рабочая машина: подключить модуль и выполнить испытание

Продолжайте в том же терминале рабочей машины и каталоге `5`.
Общее подключение `secrets-store-integration` будет временно направлено на тестовый
Vault. Исходный spec сохраняется для восстановления.

```bash
VAULT_IP=$(cat "$VAULT_TRANSFER_DIR/vault-ip")
VAULT_ADDR="https://$VAULT_IP:8200"
VAULT_CACERT="$VAULT_TRANSFER_DIR/vault-ca.pem"
kubectl get module secrets-store-integration
kubectl get moduleconfig secrets-store-integration --ignore-not-found -o json \
  > "$VAULT_TRANSFER_DIR/moduleconfig-before.json"

jq -n --arg address "$VAULT_ADDR" --rawfile ca "$VAULT_CACERT" '
{
  apiVersion: "deckhouse.io/v1alpha1",
  kind: "ModuleConfig",
  metadata: {name: "secrets-store-integration"},
  spec: {
    version: 1,
    enabled: true,
    settings: {
      connectionConfiguration: "Manual",
      connection: {
        url: $address,
        authPath: "pmi-5-kubernetes",
        caCert: $ca
      }
    }
  }
}' > "$VAULT_TRANSFER_DIR/moduleconfig-test.json"

if [ -s "$VAULT_TRANSFER_DIR/moduleconfig-before.json" ]; then
  MODULE_PATCH=$(jq -c '{spec: .spec} | .spec.settings.connection.namespace = null' "$VAULT_TRANSFER_DIR/moduleconfig-test.json")
  kubectl patch moduleconfig secrets-store-integration --type=merge \
    --dry-run=server -p "$MODULE_PATCH"
  kubectl patch moduleconfig secrets-store-integration --type=merge -p "$MODULE_PATCH"
else
  kubectl create --dry-run=server -f "$VAULT_TRANSFER_DIR/moduleconfig-test.json"
  kubectl create -f "$VAULT_TRANSFER_DIR/moduleconfig-test.json"
fi
kubectl wait --for=jsonpath='{.status.phase}'=Ready module/secrets-store-integration --timeout=180s

bash 01-prepare.sh
export EXPECTED_MARKER=pmi-value-1
bash 02-check.sh
```

`authPath` совпадает с путём из шага 4. `caCert` содержит открытый CA сервера Vault.
Merge patch удаляет прежний Vault Enterprise namespace, если он был задан.
Серверный dry-run проверяет настройки перед изменением.
[Подключение secrets-store-integration](https://deckhouse.io/modules/secrets-store-integration/configuration.html).

## 6. Сервер Vault, терминал 2: изменить маркер

```bash
vault kv put pmi/dkp-acceptance marker=pmi-value-2
```

## 7. Рабочая машина: показать обновление файла в Pod

```bash
export EXPECTED_MARKER=pmi-value-2
ROTATED=false
for ATTEMPT in {1..90}; do
  MARKER=$(kubectl -n pmi-5 exec reader -c app -- cat /mnt/external/marker)
  echo "Попытка $ATTEMPT: маркер в Pod — $MARKER"
  if [ "$MARKER" = pmi-value-2 ]; then
    ROTATED=true
    break
  fi
  sleep 2
done
if [ "$ROTATED" != true ]; then
  echo "ОШИБКА: автоматическое обновление не подтверждено за отведённое время."
else
  bash 02-check.sh
fi
```

Если установленный CSI не поддерживает авторотацию, используйте порядок
пересоздания из README пункта 5 и отметьте это в протоколе.

## 8. Сервер Vault, терминал 2: показать аудит чтения

```bash
jq -c 'select(.type == "response" and .request.path == "pmi/data/dkp-acceptance") |
  {time, operation: .request.operation, path: .request.path,
   role: .auth.metadata.role, error}' "$VAULT_TEST_DIR/audit.jsonl"
```

Найдите `operation=read`, `role=pmi-5-reader`, отсутствие ошибки.
Сохраните нужные записи аудита до очистки.

## 9. Рабочая машина: очистить кластер и восстановить подключение

```bash
bash 03-cleanup.sh
if [ -s "$VAULT_TRANSFER_DIR/moduleconfig-before.json" ]; then
  MODULE_RESTORE=$(jq -c '[{op: "replace", path: "/spec", value: .spec}]' \
    "$VAULT_TRANSFER_DIR/moduleconfig-before.json")
  kubectl patch moduleconfig secrets-store-integration --type=json -p "$MODULE_RESTORE"
else
  kubectl delete moduleconfig secrets-store-integration
fi
kubectl delete clusterrolebinding pmi-5-vault-reviewer --ignore-not-found
kubectl delete namespace pmi-5-vault --ignore-not-found --wait=true --timeout=180s
kubectl get module secrets-store-integration
```

Если модуль исходно был включён, дождитесь готовности восстановленной конфигурации.
После сохранения результатов удалите локальные файлы передачи и резервную копию:

```bash
rm -r -- ./pmi-5-vault
unset VAULT_TRANSFER_DIR VAULT_SSH VAULT_ADDR VAULT_CACERT VAULT_IP
```

## 10. Сервер Vault: завершить dev-сеанс

В терминале 1 остановите запущенный вручную Vault сочетанием **Ctrl+C**.
Секрет, роль, policy и auth backend исчезнут вместе с памятью процесса.
В терминале 2, после сохранения аудита:

```bash
rm -r -- "$VAULT_TEST_DIR"
unset VAULT_TOKEN VAULT_ADDR VAULT_CACERT VAULT_TEST_DIR VAULT_IP KUBERNETES_API
```

Команды рассчитаны на чистое тестовое окружение. При прерывании выполните
очистку только тех объектов и настроек, которые успели создать.
