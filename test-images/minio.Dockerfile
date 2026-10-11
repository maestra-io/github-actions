# MinIO server for Testcontainers (Testcontainers.Minio runs `server /data`).
# quay.io/minio/minio stopped anonymous pulls and Docker Hub no longer carries the
# RELEASE.* tags, so the image is rebuilt from the GitHub release binary, which
# mirror-test-images.yml downloads and checks against a pinned sha256.
# distroless/static: the binary is static Go; root, so `server /data` can create /data.
FROM gcr.io/distroless/static-debian12@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2
COPY minio /usr/bin/minio
EXPOSE 9000
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]
