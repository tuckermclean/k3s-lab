# syntax=docker/dockerfile:1
FROM python:3.11-slim
WORKDIR /app
# Install runtime dependencies from project metadata for reproducibility
COPY pyproject.toml ./
RUN pip install --no-cache-dir .
# Copy source last
COPY roastbot ./roastbot
COPY README.md ./
ENTRYPOINT ["python", "-m", "roastbot"]
