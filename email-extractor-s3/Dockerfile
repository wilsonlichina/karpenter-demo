# Use multi-stage build for a smaller final image
FROM --platform=$BUILDPLATFORM python:3.9-slim as builder

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Final stage
FROM --platform=$TARGETPLATFORM python:3.9-slim

WORKDIR /app

# Copy installed packages and binaries
COPY --from=builder /usr/local/lib/python3.9/site-packages/ /usr/local/lib/python3.9/site-packages/
COPY --from=builder /usr/local/bin/gunicorn /usr/local/bin/

# Copy application files
COPY app/ ./

# Create directory for S3 mount
RUN mkdir -p /mnt/s3

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV S3_MOUNT_PATH=/mnt/s3
ENV FLASK_APP=app.py

# Expose port
EXPOSE 5000

# Run with gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "app:app"]
