FROM golang:1.25-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG SOURCE_URL=https://github.com/ElmerZhang/voicedraft
RUN mkdir -p /out/licenses && cp LICENSE /out/licenses/ \
    && CGO_ENABLED=0 ./collect-notices.sh > /out/licenses/THIRD-PARTY-NOTICES.txt \
    && printf '%s\n' "$SOURCE_URL" > /out/licenses/SOURCE.txt
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/voicedraft-sync ./cmd/voicedraft-sync \
    && mkdir /out/data && chown 10001:10001 /out/data && chmod 700 /out/data

FROM scratch
COPY --from=build /out/licenses /licenses
COPY --from=build /out/voicedraft-sync /voicedraft-sync
COPY --from=build --chown=10001:10001 /out/data /data
USER 10001:10001
WORKDIR /data
ENV VOICEDRAFT_HOST=0.0.0.0 VOICEDRAFT_PORT=8765 VOICEDRAFT_DB=/data/vault.sqlite3
EXPOSE 8765
ENTRYPOINT ["/voicedraft-sync"]
