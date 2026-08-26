ARG ALPINE_IMAGE=alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

FROM ${ALPINE_IMAGE} AS rootfs

RUN apk add --no-cache \
      sgdisk=1.0.10-r1

COPY init /init
COPY prepare-gpt.sh /usr/libexec/talos-asahi/prepare-gpt

RUN chmod 0755 /init /usr/libexec/talos-asahi/prepare-gpt \
    && rm -rf /var/cache/apk /var/log/apk.log /tmp/*

FROM ${ALPINE_IMAGE} AS packer

RUN apk add --no-cache \
      cpio=2.15-r0 \
      zstd=1.5.7-r2

COPY --from=rootfs / /rootfs

RUN cd /rootfs \
    && find . -exec touch -h -d @0 {} + \
    && find . -print0 \
      | sort -z \
      | cpio --null --create --format=newc --owner=0:0 --reproducible 2>/dev/null \
      | zstd --ultra -19 --threads=0 --quiet -o /prepare-initramfs.zst

FROM rootfs AS test

COPY test-gpt.sh /usr/local/bin/test-prepare-gpt
RUN chmod 0755 /usr/local/bin/test-prepare-gpt

ENTRYPOINT ["/usr/local/bin/test-prepare-gpt"]

FROM ${ALPINE_IMAGE} AS tools

RUN apk add --no-cache \
      binutils=2.45.1-r0 \
      zip=3.0-r13

COPY --from=packer /prepare-initramfs.zst /prepare-initramfs.zst
COPY build-uki.sh /usr/local/bin/build-prepare-uki
RUN chmod 0755 /usr/local/bin/build-prepare-uki

ENTRYPOINT ["/usr/local/bin/build-prepare-uki"]
