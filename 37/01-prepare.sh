#!/usr/bin/env bash
set -euo pipefail

echo "Проверяем готовность модулей Deckhouse."
if MODULE_PHASE=$(kubectl get module "admission-policy-engine" -o jsonpath='{.status.phase}'); then
  echo "Модуль admission-policy-engine: $MODULE_PHASE"
else
  echo "ОШИБКА: не удалось получить состояние модуля admission-policy-engine. Вывод Kubernetes приведён выше."
  exit 1
fi
if [ "$MODULE_PHASE" != Ready ]; then
  echo "ОШИБКА: модуль admission-policy-engine не готов. Выполните kubectl get module admission-policy-engine -o yaml и устраните указанную там причину."
  exit 1
fi

echo "Проверяем необходимые поля API deckhouse.io/v1alpha1."
for FIELD in securitypolicy.spec.enforcementAction securitypolicy.spec.match.namespaceSelector.labelSelector securitypolicy.spec.policies.allowHostNetwork; do
  if FIELD_DESCRIPTION=$(kubectl explain "$FIELD" --api-version=deckhouse.io/v1alpha1); then
    echo "$FIELD_DESCRIPTION"
  else
    echo "ОШИБКА: API deckhouse.io/v1alpha1 не предоставляет поле $FIELD или схема недоступна. Этот вариант испытания не подходит установленному API; тестовые объекты ещё не созданы."
    exit 1
  fi
done

echo "Создаём изолированную политику RBAC и политику СЗИ для пункта 37."
kubectl create namespace pmi-37
kubectl label namespace pmi-37 pmi-test=37
kubectl -n pmi-37 create serviceaccount editor
kubectl create -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: target
  namespace: pmi-37
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: editor
  namespace: pmi-37
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles"]
  resourceNames: ["target"]
  verbs: ["get", "patch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: editor
  namespace: pmi-37
subjects:
- kind: ServiceAccount
  name: editor
  namespace: pmi-37
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: editor
---
apiVersion: deckhouse.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: pmi-37
spec:
  enforcementAction: Deny
  match:
    namespaceSelector:
      labelSelector:
        matchLabels:
          pmi-test: "37"
  policies:
    allowHostNetwork: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pmi-37-editor
rules:
- apiGroups: ["deckhouse.io"]
  resources: ["securitypolicies"]
  resourceNames: ["pmi-37"]
  verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pmi-37-editor
subjects:
- kind: ServiceAccount
  name: editor
  namespace: pmi-37
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pmi-37-editor
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reader
  namespace: pmi-37
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles"]
  resourceNames: ["target"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reader
  namespace: pmi-37
subjects:
- kind: ServiceAccount
  name: editor
  namespace: pmi-37
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reader
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pmi-37-reader
rules:
- apiGroups: ["deckhouse.io"]
  resources: ["securitypolicies"]
  resourceNames: ["pmi-37"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pmi-37-reader
subjects:
- kind: ServiceAccount
  name: editor
  namespace: pmi-37
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pmi-37-reader
YAML
echo "Подготовка завершена. Чтение тестовых политик разрешено отдельно от их изменения."
