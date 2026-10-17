#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем таблицу в конце скрипта: профиль, вариант Pod, ожидаемый allow/deny."
while read -r PROFILE VARIANT EXPECTED; do
  SECURITY='{}'
  if [ "$VARIANT" = privileged ]; then
    SECURITY='{privileged: true}'
  fi
  if [ "$VARIANT" = hardened ]; then
    SECURITY='{runAsNonRoot: true, runAsUser: 1000, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'
  fi

  echo "Профиль: $PROFILE; вариант Pod: $VARIANT; ожидаем: $EXPECTED."
  # Сервер проверяет Pod, но не создаёт его и не запускает контейнер.
  if RESULT=$(kubectl create --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: test-$VARIANT
  namespace: pmi-54-$PROFILE
spec:
  containers:
  - name: app
    image: redos_sudo
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "sleep 3600"]
    securityContext: $SECURITY
YAML
  ); then
    ACTUAL=allow
  else
    ACTUAL=deny
  fi
  echo "$RESULT"
  echo "Результат: $ACTUAL"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "ОШИБКА: результат отличается от таблицы."
    exit 1
  fi
  if [ "$ACTUAL" = deny ]; then
    if [[ "$RESULT" != *'validation.gatekeeper.sh" denied the request'* ]]; then
      echo "ОШИБКА: запрос отклонён по другой причине, запрет Gatekeeper не подтверждён."
      exit 1
    fi
  fi
done <<'TESTS'
privileged privileged allow
privileged basic      allow
privileged hardened   allow
baseline   privileged deny
baseline   basic      allow
baseline   hardened   allow
restricted privileged deny
restricted basic      deny
restricted hardened   allow
TESTS
echo "УСПЕХ: три уровня Gatekeeper соответствуют таблице. Pod проверены без запуска."
