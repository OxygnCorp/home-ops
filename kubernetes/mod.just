set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l kube

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f -

[doc('Browse a PVC')]
browse-pvc ns claim:
    kubectl run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
[script]
debug-node node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f -

[doc('Create a Foreman Workload for a GitHub issue')]
[script]
foreman-work issue name:
    kubectl apply -n ai -f - <<EOF
    apiVersion: foreman.llmkube.dev/v1alpha1
    kind: Workload
    metadata:
      name: {{ name }}
      namespace: ai
    spec:
      intent: "$(gh issue view {{ issue }} --repo OxygnCorp/home-ops --json title --jq .title)"
      repo: OxygnCorp/home-ops
      issues: [{{ issue }}]
      coderAgentRef:
        name: coder
      reviewerAgentRefs:
        - name: reviewer
    EOF

[doc('Prune pods in Failed, Pending, or Succeeded state')]
[script]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource')]
[script]
sync resource:
    kubectl get {{ resource }} --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('View a secret')]
view-secret ns secret:
    kubectl view-secret -n {{ ns }} {{ secret }}

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"

[doc('Create/update Forgejo pull-mirrors for every OxygnCorp repo (1P item forgejo: GITHUB_TOKEN + FORGEJO_TOKEN)')]
[script]
mirror-all org:
    : "${OP_VAULT:=home-ops}"
    : "${FORGEJO_URL:=https://git.oxygn.dev}"
    FORGEJO_TOKEN=$(vals get "ref+op://${OP_VAULT}/forgejo/FORGEJO_TOKEN")
    GITHUB_TOKEN=$(vals get "ref+op://${OP_VAULT}/forgejo/GITHUB_TOKEN")
    if ! curl -sfo /dev/null -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_URL}/api/v1/orgs/{{ org }}"; then
        body=$(curl -sf -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/orgs/{{ org }}" | jq -r '.description // ""' |
            jq -n -R --arg u "{{ org }}" --arg d "$(cat)" '{username: $u, visibility: "private", description: $d}')
        curl -sf -X POST -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
            -d "${body}" "${FORGEJO_URL}/api/v1/orgs" >/dev/null \
            && just log info "org created" org "{{ org }}" \
            || { just log warn "org creation failed" org "{{ org }}"; exit 1; }
    fi
    gh repo list "{{ org }}" --limit 200 --json name,sshUrl |
        jq -r ".[] | [.name, .sshUrl] | @tsv" |
        while IFS=$'\t' read -r name ssh; do
            clone_addr="https://github.com/{{ org }}/${name}.git"
            if curl -sfo /dev/null -H "Authorization: token ${FORGEJO_TOKEN}" \
                "${FORGEJO_URL}/api/v1/repos/{{ org }}/${name}"; then
                just log info "mirror exists" repo "${name}"
            else
                body=$(jq -n --arg a "${clone_addr}" --arg t "${GITHUB_TOKEN}" --arg o "{{ org }}" \
                    "{clone_addr: \$a, auth_token: \$t, mirror: true, mirror_interval: \"15m\", service: \"github\", repo_name: \"${name}\", repo_owner: \$o}")
                curl -sf -X POST -H "Authorization: token ${FORGEJO_TOKEN}" -H "Content-Type: application/json" \
                    -d "${body}" "${FORGEJO_URL}/api/v1/repos/migrate" >/dev/null \
                    && just log info "mirror created" repo "${name}" \
                    || just log warn "mirror failed" repo "${name}"
            fi
        done

[doc('Force-sync all Forgejo pull-mirrors of an org')]
[script]
mirror-sync org:
    : "${OP_VAULT:=home-ops}"
    : "${FORGEJO_URL:=https://git.oxygn.dev}"
    FORGEJO_TOKEN=$(vals get "ref+op://${OP_VAULT}/forgejo/FORGEJO_TOKEN")
    for repo in $(curl -sf -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_URL}/api/v1/orgs/{{ org }}/repos?limit=50" | jq -r ".[] | select(.mirror) | .name"); do
        curl -sf -X POST -H "Authorization: token ${FORGEJO_TOKEN}" \
            "${FORGEJO_URL}/api/v1/repos/{{ org }}/${repo}/mirror-sync" >/dev/null \
            && just log info "sync triggered" repo "${repo}"
    done
