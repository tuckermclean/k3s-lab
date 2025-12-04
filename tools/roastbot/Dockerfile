# syntax=docker/dockerfile:1
FROM python:3.11-slim
WORKDIR /app
# Copy project metadata and source
COPY pyproject.toml ./
COPY roastbot ./roastbot
# Install runtime deps and package
RUN pip install --no-cache-dir .
COPY README.md ./
ENTRYPOINT ["python", "-m", "roastbot"]
