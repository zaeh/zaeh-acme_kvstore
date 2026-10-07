# OpenVox agent (ACME worker and consumer) for the end-to-end tests.
FROM ghcr.io/letsencrypt/pebble:2.10.1 AS pebble

FROM rockylinux/rockylinux:9.8.20260525.0

ARG OPENVOX_VERSION=8
ARG AGENT_VERSION

RUN dnf install -y "https://yum.voxpupuli.org/openvox${OPENVOX_VERSION}-release-el-9.noarch.rpm" \
 && dnf install -y "openvox-agent-${AGENT_VERSION}" hostname \
 && dnf clean all

# Trust Pebble's test TLS CA like an internal ACME CA.
COPY --from=pebble /test/certs/pebble.minica.pem /etc/pki/ca-trust/source/anchors/pebble-minica.pem
RUN update-ca-trust

ENV PATH=/opt/puppetlabs/bin:$PATH
CMD ["sleep", "infinity"]
