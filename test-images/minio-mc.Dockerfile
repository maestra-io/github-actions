# syntax=docker/dockerfile:1.28
# MinIO server plus the `mc` client, for Testcontainers fixtures that exec `mc`
# inside the server container (quay.io/minio/minio ships it; dm-serving
# MinioTestFixture). mirror-test-images.yml downloads and verifies `mc`; the
# server binary is the same pinned release as test-images/minio.Dockerfile,
# verified by ADD --checksum.
FROM gcr.io/distroless/static-debian12@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2
ADD --chmod=0755 --checksum=sha256:7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f \
    https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z /usr/bin/minio
COPY mc /usr/bin/mc
# mc keeps its aliases under $HOME/.mc.
ENV HOME=/root
EXPOSE 9000
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
