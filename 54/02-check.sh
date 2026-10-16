#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем матрицу из девяти запросов создания через серверный dry-run."
for PROFILE in privileged baseline restricted; do
  for VARIANT in privileged basic hardened; do
    SECURITY='{}'
    EXPECT_DENY=false
    if [ "$VARIANT" = privileged ]; then
      SECURITY='{privileged: true}'
      if [ "$PROFILE" != privileged ]; then
        EXPECT_DENY=true
      fi
    fi
    if [ "$VARIANT" = basic ] && [ "$PROFILE" = restricted ]; then
      EXPECT_DENY=true
    fi
    if [ "$VARIANT" = hardened ]; then
      SECURITY='{runAsNonRoot: true, runAsUser: 1000, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'
    fi
    echo "Профиль: $PROFILE; вариант Pod: $VARIANT; ожидается запрет: $EXPECT_DENY"
    if RESULT=$(kubectl create --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: test-$VARIANT
  namespace: pmi-54-$PROFILE
spec:
  containers:
  - name: app
    image: busybox:1.36.1
    command: ["sh", "-c", "sleep 3600"]
    securityContext: $SECURITY
YAML
    ); then
      echo "$RESULT"
      if [ "$EXPECT_DENY" = true ]; then
        echo "ОШИБКА: небезопасный запрос разрешён. Проверьте режим deny и синхронизацию Gatekeeper."
        exit 1
      fi
    else
      echo "$RESULT"
      if [ "$EXPECT_DENY" = false ]; then
        echo "ОШИБКА: контрольный запрос отклонён."
        exit 1
      fi
      if [[ "$RESULT" != *'gatekeeper'* || "$RESULT" != *'denied the request'* ]]; then
        echo "ОШИБКА: запрет не подтверждён ответом Gatekeeper."
        exit 1
      fi
    fi
  done
done
echo "УСПЕХ: три уровня Gatekeeper различаются по ожидаемой матрице. Pod проверены без запуска."
