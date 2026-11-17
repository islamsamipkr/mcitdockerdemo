FROM python:3.12-slim
WORKDIR /app
COPY app.py .
# Do not run the web server as root.
RUN useradd --system --uid 10001 --no-create-home appuser
USER appuser
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c 'from urllib.request import urlopen; urlopen("http://127.0.0.1:8080/health", timeout=2)' || exit 1
CMD ["python", "app.py"]
