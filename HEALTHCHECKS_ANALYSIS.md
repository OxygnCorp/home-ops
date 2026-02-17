# Kustomization healthChecks Analysis Report

**Date:** 2026-02-17  
**Analysis Type:** Blocking Kustomizations Without healthChecks

## Executive Summary

- **Total ks.yaml files analyzed:** 70
- **Total Kustomization resources found:** 84
- **Blocking Kustomizations (referenced by others):** 24
- **Blocking Kustomizations WITHOUT healthChecks:** 14

A "blocking Kustomization" is one that is referenced in the `dependsOn` field of other Kustomizations, meaning they must be healthy before dependent resources are applied.

---

## Detailed Findings

### 1. certificates-import
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/network/certificates/ks.yaml`
- **Namespace:** `network`
- **HelmRelease Name:** `certificates-import`
- **HelmRelease Namespace:** `network`
- **Current Status:** NO healthChecks defined
- **Referenced by:** `certificates-export`

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: certificates-import
      namespace: network
```

---

### 2. cloudnative-pg
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/database/cloudnative-pg/ks.yaml`
- **Namespace:** `database`
- **HelmRelease Name:** `cloudnative-pg`
- **HelmRelease Namespace:** `database`
- **Current Status:** NO healthChecks defined
- **Referenced by:** `cloudnative-pg-cluster`

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: cloudnative-pg
      namespace: database
```

---

### 3. cloudnative-pg-barman
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/database/cloudnative-pg/ks.yaml`
- **Namespace:** `database`
- **HelmRelease Name:** `cloudnative-pg-barman`
- **HelmRelease Namespace:** `database`
- **Current Status:** NO healthChecks defined
- **Referenced by:** `cloudnative-pg-cluster`

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: cloudnative-pg-barman
      namespace: database
```

---

### 4. cloudnative-pg-cluster
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/database/cloudnative-pg/ks.yaml`
- **Namespace:** `database`
- **HelmRelease Name:** `cloudnative-pg-cluster`
- **HelmRelease Namespace:** `database`
- **Current Status:** NO healthChecks defined
- **Referenced by:** (Flux depends on this, primary workload)

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: cloudnative-pg-cluster
      namespace: database
```

---

### 5. dragonfly
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/database/dragonfly/ks.yaml`
- **Namespace:** `database`
- **HelmRelease Name:** `dragonfly`
- **HelmRelease Namespace:** `database`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: dragonfly
      namespace: database
```

---

### 6. external-secrets
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/external-secrets/external-secrets/ks.yaml`
- **Namespace:** `external-secrets`
- **HelmRelease Name:** `external-secrets`
- **HelmRelease Namespace:** `external-secrets`
- **Current Status:** NO healthChecks defined
- **Referenced by:** Multiple applications requiring external secret management

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: external-secrets
      namespace: external-secrets
```

---

### 7. flux-operator
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/flux-system/flux-operator/ks.yaml`
- **Namespace:** `flux-system`
- **HelmRelease Name:** `flux-operator`
- **HelmRelease Namespace:** `flux-system`
- **Current Status:** NO healthChecks defined
- **Critical:** Core Flux component

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: flux-operator
      namespace: flux-system
```

---

### 8. grafana
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/observability/grafana/ks.yaml`
- **Namespace:** `observability`
- **HelmRelease Name:** `grafana`
- **HelmRelease Namespace:** `observability`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: grafana
      namespace: observability
```

---

### 9. mosquitto
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/automation/mosquitto/ks.yaml`
- **Namespace:** `automation`
- **HelmRelease Name:** `mosquitto`
- **HelmRelease Namespace:** `automation`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: mosquitto
      namespace: automation
```

---

### 10. multus-networks
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/kube-system/multus/ks.yaml`
- **Namespace:** `kube-system`
- **HelmRelease Name:** `multus-networks`
- **HelmRelease Namespace:** `kube-system`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: multus-networks
      namespace: kube-system
```

---

### 11. node-feature-discovery
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/kube-system/node-feature-discovery/ks.yaml`
- **Namespace:** `kube-system`
- **HelmRelease Name:** `node-feature-discovery`
- **HelmRelease Namespace:** `kube-system`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: node-feature-discovery
      namespace: kube-system
```

---

### 12. openebs
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/openebs-system/openebs/ks.yaml`
- **Namespace:** `openebs-system`
- **HelmRelease Name:** `openebs`
- **HelmRelease Namespace:** `openebs-system`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: openebs
      namespace: openebs-system
```

---

### 13. tuppr
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/system-upgrade/tuppr/ks.yaml`
- **Namespace:** `system-upgrade`
- **HelmRelease Name:** `tuppr`
- **HelmRelease Namespace:** `system-upgrade`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: tuppr
      namespace: system-upgrade
```

---

### 14. volsync
- **File:** `/home/nea0d/git/home-ops/kubernetes/apps/volsync-system/volsync/ks.yaml`
- **Namespace:** `volsync-system`
- **HelmRelease Name:** `volsync`
- **HelmRelease Namespace:** `volsync-system`
- **Current Status:** NO healthChecks defined

**Proposed Addition:**
```yaml
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: volsync
      namespace: volsync-system
```

---

## Implementation Instructions

For each Kustomization above:

1. **Open the ks.yaml file**
2. **Locate the Kustomization resource definition** (it's one of the YAML documents in the file)
3. **Add the healthChecks block to the `spec:` section**

### Example Before:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
spec:
  interval: 1h
  path: ./kubernetes/apps/example
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: example
  wait: false
```

### Example After:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
spec:
  interval: 1h
  path: ./kubernetes/apps/example
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: example
  wait: false
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: example
      namespace: example
```

---

## Why This Matters

Adding `healthChecks` to blocking Kustomizations provides several benefits:

1. **Ensures Readiness:** Flux will wait for the HelmRelease to be ready before applying dependent resources
2. **Prevents Cascading Failures:** Dependent Kustomizations won't be deployed if the blocking resource isn't healthy
3. **Better Visibility:** Makes the dependency chain explicit in both the source and Flux status
4. **Graceful Deployments:** Orchestrates your cluster initialization more predictably during upgrades and restarts

---

## Files Requiring Updates

```
1. /home/nea0d/git/home-ops/kubernetes/apps/network/certificates/ks.yaml
2. /home/nea0d/git/home-ops/kubernetes/apps/database/cloudnative-pg/ks.yaml (3 Kustomizations)
3. /home/nea0d/git/home-ops/kubernetes/apps/database/dragonfly/ks.yaml
4. /home/nea0d/git/home-ops/kubernetes/apps/external-secrets/external-secrets/ks.yaml
5. /home/nea0d/git/home-ops/kubernetes/apps/flux-system/flux-operator/ks.yaml
6. /home/nea0d/git/home-ops/kubernetes/apps/observability/grafana/ks.yaml
7. /home/nea0d/git/home-ops/kubernetes/apps/automation/mosquitto/ks.yaml
8. /home/nea0d/git/home-ops/kubernetes/apps/kube-system/multus/ks.yaml
9. /home/nea0d/git/home-ops/kubernetes/apps/kube-system/node-feature-discovery/ks.yaml
10. /home/nea0d/git/home-ops/kubernetes/apps/openebs-system/openebs/ks.yaml
11. /home/nea0d/git/home-ops/kubernetes/apps/system-upgrade/tuppr/ks.yaml
12. /home/nea0d/git/home-ops/kubernetes/apps/volsync-system/volsync/ks.yaml
```

---

## Summary Table

| Kustomization | File | Namespace | Status |
|---|---|---|---|
| certificates-import | network/certificates/ks.yaml | network | Missing healthChecks |
| cloudnative-pg | database/cloudnative-pg/ks.yaml | database | Missing healthChecks |
| cloudnative-pg-barman | database/cloudnative-pg/ks.yaml | database | Missing healthChecks |
| cloudnative-pg-cluster | database/cloudnative-pg/ks.yaml | database | Missing healthChecks |
| dragonfly | database/dragonfly/ks.yaml | database | Missing healthChecks |
| external-secrets | external-secrets/external-secrets/ks.yaml | external-secrets | Missing healthChecks |
| flux-operator | flux-system/flux-operator/ks.yaml | flux-system | Missing healthChecks |
| grafana | observability/grafana/ks.yaml | observability | Missing healthChecks |
| mosquitto | automation/mosquitto/ks.yaml | automation | Missing healthChecks |
| multus-networks | kube-system/multus/ks.yaml | kube-system | Missing healthChecks |
| node-feature-discovery | kube-system/node-feature-discovery/ks.yaml | kube-system | Missing healthChecks |
| openebs | openebs-system/openebs/ks.yaml | openebs-system | Missing healthChecks |
| tuppr | system-upgrade/tuppr/ks.yaml | system-upgrade | Missing healthChecks |
| volsync | volsync-system/volsync/ks.yaml | volsync-system | Missing healthChecks |

---

**Report Generated:** 2026-02-17
