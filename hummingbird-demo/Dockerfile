# Multi-stage build: Hummingbird builder → hardened runtime (Project Hummingbird / RHACS 4.11 demo)
ARG HI_PYTHON_TAG=3.13
FROM registry.access.redhat.com/hi/python:${HI_PYTHON_TAG}-builder AS builder
USER 0
RUN pip install --no-cache-dir flask==3.0.0
COPY app.py /app/app.py

FROM registry.access.redhat.com/hi/python:${HI_PYTHON_TAG}
COPY --from=builder /app/app.py /app/app.py
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
WORKDIR /app
EXPOSE 8080
CMD ["python3", "/app/app.py"]
