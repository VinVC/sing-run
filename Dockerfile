FROM alpine:3.21

ARG TARGETARCH
ARG SING_BOX_VERSION=1.11.0

RUN apk add --no-cache \
    zsh \
    curl \
    jq \
    python3 \
    procps

RUN ARCH=$(case "${TARGETARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}" in \
      amd64) echo amd64 ;; arm64) echo arm64 ;; *) echo amd64 ;; esac) && \
    curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

RUN ARCH=$(case "${TARGETARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}" in \
      amd64) echo amd64 ;; arm64) echo arm64 ;; *) echo amd64 ;; esac) && \
    curl -sL "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz" \
      -o /tmp/sb.tar.gz && \
    tar xzf /tmp/sb.tar.gz -C /tmp && \
    mv /tmp/sing-box-*/sing-box /usr/local/bin/ && \
    rm -rf /tmp/sb* && \
    sing-box version

WORKDIR /app

COPY sing-run.sh sing-run-system.sh sing-run-rules.sh sing-run-template.sh \
     sing-run-region.sh sing-run-instance.sh sing-run-source.sh sing-run-plugin.sh \
     sources.sh.example ./
COPY templates/ ./templates/

RUN mkdir -p /data /app/plugins /app/custom && \
    ln -sf /data /root/.sing-run

COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

VOLUME /data

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["--help"]
