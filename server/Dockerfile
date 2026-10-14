FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/voicedraft-sync ./cmd/voicedraft-sync \
    && mkdir /out/data && chown 10001:10001 /out/data && chmod 700 /out/data

FROM scratch
COPY --from=build /out/voicedraft-sync /voicedraft-sync
COPY --from=build --chown=10001:10001 /out/data /data
USER 10001:10001
WORKDIR /data
ENV VOICEDRAFT_HOST=0.0.0.0 VOICEDRAFT_PORT=8765 VOICEDRAFT_DB=/data/vault.sqlite3
EXPOSE 8765
ENTRYPOINT ["/voicedraft-sync"]
