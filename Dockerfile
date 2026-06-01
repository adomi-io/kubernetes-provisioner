# kubernetes-provisioner: bundles kubectl + helm + helmfile + the provisioner tree.
# Provision the cluster apps by mounting a kubeconfig:
#
#   docker run --rm -it \
#     -v "$HOME/.kube/config:/root/.kube/config:ro" \
#     ghcr.io/adomi-io/kubernetes-provisioner:latest \
#     apply
#
FROM alpine:3.20

ARG KUBECTL_VERSION=v1.31.4
ARG HELM_VERSION=v4.2.0
ARG HELMFILE_VERSION=1.5.2
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl ca-certificates git tar \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${TARGETARCH}" && chmod +x /usr/local/bin/helm \
 && curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${TARGETARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin helmfile \
 && chmod +x /usr/local/bin/helmfile \
 && helm plugin install https://github.com/databus23/helm-diff --verify=false

WORKDIR /provisioner
COPY . .

ENTRYPOINT ["helmfile"]
