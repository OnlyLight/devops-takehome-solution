# Rendered by scripts/20-deploy.sh (envsubst on REPO_URL and TARGET_REVISION).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: quote-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: chart/quote-api
  destination:
    server: https://kubernetes.default.svc
    namespace: quote-api
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
