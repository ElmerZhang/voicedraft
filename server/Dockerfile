FROM python:3.12-slim
WORKDIR /app
COPY server.py .
RUN useradd --uid 10001 --create-home voicedraft && mkdir /data && chown voicedraft:voicedraft /data
USER voicedraft
ENV VOICEDRAFT_HOST=0.0.0.0 VOICEDRAFT_PORT=8765 VOICEDRAFT_DB=/data/vault.sqlite3
EXPOSE 8765
CMD ["python", "-u", "server.py"]
