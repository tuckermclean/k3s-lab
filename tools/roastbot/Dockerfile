# syntax=docker/dockerfile:1
FROM python:3.11-slim
WORKDIR /app
# Install runtime dependencies first for better layer caching
COPY pyproject.toml ./
RUN pip install --no-cache-dir \
    httpx>=0.27 \
    pyyaml>=6.0 \
    pydantic>=2.9 \
    tenacity>=8.4 \
    rich>=13.7 \
    typer>=0.12 \
    openai>=1.51.0
# Copy source last
COPY roastbot ./roastbot
COPY README.md ./
ENTRYPOINT ["python", "-m", "roastbot"]
