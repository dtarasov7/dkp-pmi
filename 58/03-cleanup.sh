#!/usr/bin/env bash
set -euo pipefail

echo "Удаляем только данные и копию данного испытания."
kubectl -n velero delete restore pmi-58 --ignore-not-found
# CLI Velero создаёт запрос удаления копии также из объектного хранилища.
BACKUP=$(kubectl -n velero get backup pmi-58 --ignore-not-found -o name)
echo "Созданная копия: $BACKUP"
if [ -n "$BACKUP" ]; then
  velero backup delete pmi-58 --confirm
else
  echo "Копия отсутствует, удаляем оставшиеся тестовые объекты."
fi
kubectl delete namespace pmi-58 pmi-58-restored --ignore-not-found --wait=true --timeout=180s
