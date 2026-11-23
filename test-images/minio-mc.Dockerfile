# syntax=docker/dockerfile:1.28
# MinIO server plus the `mc` client, for Testcontainers fixtures that exec `mc`
# inside the server container (quay.io/minio/minio ships it; dm-serving
# MinioTestFixture). mirror-test-images.yml downloads both binaries from nora and
# verifies them; the server is the same pinned release as test-images/minio.Dockerfile.
FROM packages.maestra.io/gcr/distroless/static-debian12@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2
COPY minio /usr/bin/minio
COPY mc /usr/bin/mc
# mc keeps its aliases under $HOME/.mc.
ENV HOME=/root
EXPOSE 9000
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
