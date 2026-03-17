FROM alpine:3.20

ARG FRP_VERSION=0.67.0
ARG TARGETARCH

RUN set -eux; \
    apk add --no-cache ca-certificates tar wget; \
    case "${TARGETARCH}" in \
      amd64) FRP_ARCH="amd64" ;; \
      arm64) FRP_ARCH="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -O /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"; \
    tar -xzf /tmp/frp.tar.gz -C /tmp; \
    cp "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" /usr/local/bin/frps; \
    cp "/tmp/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frpc" /usr/local/bin/frpc; \
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc; \
    rm -rf /tmp/frp*; \
    adduser -D -H -s /sbin/nologin frp

USER frp
WORKDIR /etc/frp
