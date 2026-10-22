# Container image for the AWS Proj-5 web app.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies first so this layer is cached between builds.
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Version shown by /health (passed in by the pipeline).
ARG APP_VERSION=dev
RUN echo "$APP_VERSION" > /app/VERSION

# Run as a non-root user.
RUN useradd --system --no-create-home appuser
USER appuser

EXPOSE 8000

# slim images have no curl, so use Python for the container health check.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
