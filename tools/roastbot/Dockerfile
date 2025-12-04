# syntax=docker/dockerfile:1
FROM python:3.11-slim
WORKDIR /app
COPY pyproject.toml ./
RUN pip install --no-cache-dir .[dev]
COPY roastbot ./roastbot
COPY README.md ./
ENTRYPOINT ["python", "-m", "roastbot"]
