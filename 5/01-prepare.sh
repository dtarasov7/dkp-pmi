#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "secrets-store-integration" -o jsonpath='{.status.phase}'); then
  echo "Модуль secrets-store-integration: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля secrets-store-integration. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль secrets-store-integration не готов. Выполните kubectl get module secrets-store-integration -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Проверяем необходимые поля API deckhouse.io/v1alpha1."
for FIELD in secretsstoreimport.spec.type secretsstoreimport.spec.role secretsstoreimport.spec.files.source.path secretsstoreimport.spec.files.source.key; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=deckhouse.io/v1alpha1); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API deckhouse.io/v1alpha1 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Проверяем регистрацию драйвера, который монтирует внешний секрет в Pod."
if CSI_DRIVER=$(kubectl get csidriver secrets-store.csi.deckhouse.io -o name); then
  echo "Драйвер CSI: $CSI_DRIVER"
else
  echo "ОШИБКА: драйвер secrets-store.csi.deckhouse.io недоступен. Проверьте установку CSI-компонента secrets-store-integration."
  exit 1
fi

echo "Создаём импорт тестового секрета из внешнего хранилища."
kubectl create namespace pmi-5
kubectl -n pmi-5 create serviceaccount reader
kubectl create -f - <<'YAML'
apiVersion: deckhouse.io/v1alpha1
kind: SecretsStoreImport
metadata:
  name: external-secret
  namespace: pmi-5
spec:
  type: CSI
  role: pmi-5-reader
  files:
  - name: marker
    source:
      path: pmi/data/dkp-acceptance
      key: marker
---
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: pmi-5
spec:
  serviceAccountName: reader
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: redos_sudo
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: external
      mountPath: /mnt/external
      readOnly: true
  volumes:
  - name: external
    csi:
      driver: secrets-store.csi.deckhouse.io
      readOnly: true
      volumeAttributes:
        secretsStoreImport: external-secret
YAML
kubectl -n pmi-5 wait --for=condition=Ready pod/reader --timeout=180s
echo "Подготовка завершена."
