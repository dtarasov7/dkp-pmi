#!/usr/bin/env bash
set -euo pipefail

echo "Шаг 1. Меняем число реплик: 2 → 3 → 1. После каждого изменения ждём готовности."
for REPLICAS in 2 3 1; do
  kubectl -n pmi-21 scale deployment resource-limits --replicas="$REPLICAS"
  kubectl -n pmi-21 rollout status deployment/resource-limits --timeout=180s
  kubectl -n pmi-21 wait --for=jsonpath='{.status.replicas}'="$REPLICAS" deployment/resource-limits --timeout=180s
  kubectl -n pmi-21 get deployment resource-limits
  kubectl -n pmi-21 get pods -l app=pmi-21-resources -o wide

  echo "У каждой реплики ожидаем requests 50m/32Mi и limits 100m/64Mi."
  PODS=$(kubectl -n pmi-21 get pods -l app=pmi-21-resources -o name)
  for POD in $PODS; do
    RESOURCES=$(kubectl -n pmi-21 get "$POD" -o jsonpath='{.spec.containers[0].resources.requests.cpu} {.spec.containers[0].resources.requests.memory} {.spec.containers[0].resources.limits.cpu} {.spec.containers[0].resources.limits.memory}')
    echo "$POD: $RESOURCES"
    if [ "$RESOURCES" != '50m 32Mi 100m 64Mi' ]; then
      echo "ОШИБКА: ресурсы Pod отличаются от манифеста."
      exit 1
    fi
  done
done

POD=$(kubectl -n pmi-21 get pods -l app=pmi-21-resources -o jsonpath='{.items[0].metadata.name}')
echo "Шаг 2. Нагружаем CPU контейнера $POD и проверяем ограничение до 100m."
kubectl -n pmi-21 exec -i "$POD" -c app -- sh -s <<'SHELL'
set -eu
CPU_STAT=$(find /sys/fs/cgroup -name cpu.stat -print -quit)
CPU_DIRECTORY=$(dirname "$CPU_STAT")
echo "Счётчики CPU: $CPU_STAT"

# В cgroup v2 квота и период записаны вместе; в v1 — в двух файлах.
if [ -f "$CPU_DIRECTORY/cpu.max" ]; then
  read -r QUOTA PERIOD < "$CPU_DIRECTORY/cpu.max"
else
  QUOTA=$(cat "$CPU_DIRECTORY/cpu.cfs_quota_us")
  PERIOD=$(cat "$CPU_DIRECTORY/cpu.cfs_period_us")
fi
echo "Квота CPU: $QUOTA; период: $PERIOD микросекунд. Ожидаем отношение 1:10."
if [ "$QUOTA" != "$((PERIOD / 10))" ]; then
  echo "ОШИБКА: квота CPU не соответствует 100m."
  exit 1
fi

BEFORE=$(awk '$1 == "nr_throttled" {print $2}' "$CPU_STAT")
stress-ng --cpu 1 --cpu-method loop --timeout 15s --metrics-brief
AFTER=$(awk '$1 == "nr_throttled" {print $2}' "$CPU_STAT")
echo "Число ограничений CPU (nr_throttled): до $BEFORE, после $AFTER."
if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
  echo "ОШИБКА: в cpu.stat отсутствует счётчик nr_throttled."
  exit 1
fi
if [ "$AFTER" -le "$BEFORE" ]; then
  echo "ОШИБКА: ограничение CPU под нагрузкой не подтверждено."
  exit 1
fi
SHELL

echo "Шаг 3. В отдельном Job выделяем 16 MiB, затем пытаемся выделить 256 MiB при лимите 64Mi."
kubectl create -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: memory-limit
  namespace: pmi-21
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: memory
        image: redos_sudo
        imagePullPolicy: IfNotPresent
        command: ["sh", "-ec"]
        args:
        - |
          if [ -f /sys/fs/cgroup/memory.max ]; then
            LIMIT=$(cat /sys/fs/cgroup/memory.max)
          else
            LIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
          fi
          echo "Лимит памяти cgroup: $LIMIT байт (ожидаем 67108864)."
          if [ "$LIMIT" != 67108864 ]; then
            echo "ОШИБКА: фактический лимит памяти не равен 64Mi."
            exit 1
          fi
          python3 -c 'memory = bytearray(16 * 1024 * 1024); print("Контрольное выделение 16 MiB выполнено.")'
          echo "Пытаемся выделить 256 MiB при лимите 64Mi."
          exec python3 -c 'memory = bytearray(256 * 1024 * 1024)'
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
YAML
kubectl -n pmi-21 wait --for=condition=Failed job/memory-limit --timeout=180s
MEMORY_POD=$(kubectl -n pmi-21 get pods -l job-name=memory-limit -o jsonpath='{.items[0].metadata.name}')
MEMORY_LOG=$(kubectl -n pmi-21 logs "$MEMORY_POD" -c memory)
echo "$MEMORY_LOG"
if [[ "$MEMORY_LOG" != *'Контрольное выделение 16 MiB выполнено.'* ]]; then
  echo "ОШИБКА: контрольное выделение памяти не выполнено."
  exit 1
fi
MEMORY_LIMIT=$(kubectl -n pmi-21 get pod "$MEMORY_POD" -o jsonpath='{.spec.containers[0].resources.limits.memory}')
RESULT=$(kubectl -n pmi-21 get pod "$MEMORY_POD" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason} {.status.containerStatuses[0].state.terminated.exitCode}')
echo "Лимит Pod: $MEMORY_LIMIT; результат: $RESULT. Ожидаем 64Mi и OOMKilled 137."
if [ "$MEMORY_LIMIT" != 64Mi ] || [ "$RESULT" != 'OOMKilled 137' ]; then
  echo "ОШИБКА: завершение контейнера не подтверждает ожидаемый OOMKilled."
  exit 1
fi

echo "Шаг 4. Обычный Deployment должен продолжать работать."
kubectl -n pmi-21 rollout status deployment/resource-limits --timeout=120s
kubectl -n pmi-21 wait --for=condition=Ready "pod/$POD" --timeout=60s
kubectl -n pmi-21 get pods -o wide
echo "УСПЕХ: проверены replicas 2 → 3 → 1, requests/limits, CPU throttling и OOMKilled при превышении памяти."
