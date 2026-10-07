# OpenVox agent (ACME worker and consumer) for the end-to-end tests.
FROM ghcr.io/letsencrypt/pebble:2.10.1 AS pebble

FROM ubuntu:noble-20260917

ARG OPENVOX_VERSION=8
ARG AGENT_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSLo /tmp/openvox-release.deb "https://apt.voxpupuli.org/openvox${OPENVOX_VERSION}-release-ubuntu24.04.deb" \
 && apt-get install -y /tmp/openvox-release.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends "openvox-agent=${AGENT_VERSION}-1+ubuntu24.04" \
 && rm -rf /tmp/openvox-release.deb

# Trust Pebble's test TLS CA like an internal ACME CA.
COPY --from=pebble /test/certs/pebble.minica.pem /usr/local/share/ca-certificates/pebble-minica.crt
RUN update-ca-certificates

ENV PATH=/opt/puppetlabs/bin:$PATH
CMD ["sleep", "infinity"]
