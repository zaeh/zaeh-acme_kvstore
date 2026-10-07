# The official OpenVox server image plus the redis gem, as docs/redis.md
# asks of every server compiling acme_kvstore::deploy.
FROM ghcr.io/openvoxproject/openvoxserver:8.16.0

RUN puppetserver gem install redis --version 5.4.1 --no-document
