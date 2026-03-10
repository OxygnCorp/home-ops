---
applyTo: "components/volsync/**/*.yaml"
---

# Instructions for VolSync Integration

## Overview
VolSync provides persistent storage backup and synchronization for applications requiring data persistence.

## Configuration Guidelines

### ReplicationSource and ReplicationDestination
- Use appropriate API versions for VolSync resources
- Configure schedules for automated backups
- Set retention policies for backup management
- Use proper storage class references

### Schema Validation
Include Kubernetes schema headers for Deployments, PVCs, etc., and VolSync-specific schemas if available.

### Best Practices
- Configure backup schedules during low-usage periods
- Use appropriate retention policies to manage storage
- Test restore procedures regularly
- Document backup and restore processes
- Use ESO for any required credentials

### Example ReplicationSource
```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: my-app-backup
spec:
  sourcePVC: my-app-data
  trigger:
    schedule: "0 2 * * *"  # Daily at 2 AM
  restic:
    repository: restic-secret
    retain:
      daily: 7
      weekly: 4
      monthly: 12
```

### Integration with Applications
- Reference VolSync components in app kustomizations
- Ensure PVCs are properly labeled for backup
- Configure health checks for backup status
