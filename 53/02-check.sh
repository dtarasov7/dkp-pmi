#!/usr/bin/env bash
set -euo pipefail

SERVER_IP=$(kubectl -n pmi-53 get pod server -o jsonpath='{.status.podIP}')
echo "Адрес сервера: $SERVER_IP"
echo "До политики: HTTP-запрос должен проходить."
kubectl -n pmi-53 exec client -c app -- wget -T 3 -qO- "http://$SERVER_IP:8080/"
echo "Откройте Hubble, выберите pmi-53 и включите отображение dropped flows."
echo "Применяем запрет ingress только к тестовому серверу."
kubectl create -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-server
  namespace: pmi-53
spec:
  podSelector:
    matchLabels:
      app: server
  policyTypes: [Ingress]
  ingress: []
YAML
BLOCKED=false
for ATTEMPT in {1..20}; do
  if RESULT=$(kubectl -n pmi-53 exec client -c app -- wget -T 3 -qO- "http://$SERVER_IP:8080/" 2>&1); then
    echo "Попытка $ATTEMPT: политика ещё применяется. Ответ: $RESULT"
  else
    echo "$RESULT"
    if [[ "$RESULT" != *'wget:'* || "$RESULT" != *'timed out'* ]]; then
      echo "ОШИБКА: это не ожидаемый тайм-аут сетевого запрета."
      exit 1
    fi
    BLOCKED=true
    break
  fi
  sleep 2
done
if [ "$BLOCKED" != true ]; then
  echo "ОШИБКА: запрет не вступил в силу."
  exit 1
fi
echo "Проверяем работоспособность самого сервера."
kubectl -n pmi-53 exec server -c app -- wget -T 3 -qO- http://127.0.0.1:8080/
echo "Повторяем запросы для фиксации dropped flows в Hubble."
for ATTEMPT in {1..5}; do
  if RESULT=$(kubectl -n pmi-53 exec client -c app -- wget -T 3 -qO- "http://$SERVER_IP:8080/" 2>&1); then
    echo "ОШИБКА: доступ неожиданно восстановился. Ответ: $RESULT"
    exit 1
  fi
  echo "$RESULT"
  if [[ "$RESULT" != *'wget:'* || "$RESULT" != *'timed out'* ]]; then
    echo "ОШИБКА: неожиданный отказ."
    exit 1
  fi
done
echo "Сетевой отказ воспроизведён. Для приёмки подтвердите POLICY_DENIED в Hubble по README."
