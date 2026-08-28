ARG ALPINE_IMAGE=alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

FROM golang:1.26-alpine3.23@sha256:b17af760035fc2f338eed92d448a6c67f2d45438844fc6c60678fa5f99e44b57 AS meta-builder

WORKDIR /src
COPY meta-uuid/go.mod ./
COPY meta-uuid/main.go meta-uuid/main_test.go ./

RUN CGO_ENABLED=0 go test ./... \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /meta-uuid .

FROM ${ALPINE_IMAGE} AS rootfs

RUN apk add --no-cache \
      sgdisk=1.0.10-r1

COPY init /init
COPY prepare-gpt.sh /usr/libexec/talos-asahi/prepare-gpt
COPY --from=meta-builder /meta-uuid /usr/libexec/talos-asahi/meta-uuid

RUN chmod 0755 \
      /init \
      /usr/libexec/talos-asahi/meta-uuid \
      /usr/libexec/talos-asahi/prepare-gpt \
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
      zstd=1.5.7-r2 \
      zip=3.0-r13

COPY --from=packer /prepare-initramfs.zst /prepare-initramfs.zst
COPY build-uki.sh /usr/local/bin/build-prepare-uki
RUN chmod 0755 /usr/local/bin/build-prepare-uki

ENTRYPOINT ["/usr/local/bin/build-prepare-uki"]
