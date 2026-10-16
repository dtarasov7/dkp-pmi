#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем клиент Velero и доступность хранилища резервных копий."
if VELERO_VERSION=$(velero version --client-only); then
  echo "$VELERO_VERSION"
else
  echo "ОШИБКА: клиент velero недоступен. Установите CLI версии, совместимой с установленным сервером Velero."
  exit 1
fi
BACKUP_STORAGE_LOCATION=${BACKUP_STORAGE_LOCATION:-default}
if STORAGE_PHASE=$(kubectl -n velero get backupstoragelocation "$BACKUP_STORAGE_LOCATION" -o jsonpath='{.status.phase}'); then
  echo "Хранилище $BACKUP_STORAGE_LOCATION: $STORAGE_PHASE"
else
  echo "ОШИБКА: хранилище Velero недоступно. Покажите kubectl -n velero get backupstoragelocations и укажите нужное имя в BACKUP_STORAGE_LOCATION."
  exit 1
fi
if [ "$STORAGE_PHASE" != Available ]; then
  echo "ОШИБКА: хранилище не готово. Выполните kubectl -n velero describe backupstoragelocation $BACKUP_STORAGE_LOCATION и устраните причину."
  exit 1
fi
STORAGE_ACCESS_MODE=$(kubectl -n velero get backupstoragelocation "$BACKUP_STORAGE_LOCATION" -o jsonpath='{.spec.accessMode}')
echo "Режим доступа к хранилищу: ${STORAGE_ACCESS_MODE:-ReadWrite (по умолчанию)}"
if [ "$STORAGE_ACCESS_MODE" = ReadOnly ]; then
  echo "ОШИБКА: хранилище доступно только для чтения; создать резервную копию нельзя."
  exit 1
fi

echo "Создаём отдельные данные для проверки резервного копирования Velero."
kubectl create namespace pmi-58
kubectl -n pmi-58 create configmap marker --from-literal=value=pmi-58-backup
velero backup create pmi-58 --storage-location "$BACKUP_STORAGE_LOCATION" --include-namespaces pmi-58 --include-resources configmaps --snapshot-volumes=false --wait
echo "Резервная копия запрошена. Её статус проверяется отдельно."
