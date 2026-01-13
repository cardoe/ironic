FROM python:3.11-slim

LABEL maintainer="Ironic Developers"
LABEL description="Kubernetes controller for Ironic InspectionRule CRDs"

# Create non-root user
RUN groupadd -r ironic && useradd -r -g ironic ironic

WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy controller script
COPY inspection_rules_controller.py .

# Set permissions
RUN chmod +x inspection_rules_controller.py && \
    chown -R ironic:ironic /app

# Create directory for output file
RUN mkdir -p /etc/ironic && chown ironic:ironic /etc/ironic

# Switch to non-root user
USER ironic

# Set entrypoint
ENTRYPOINT ["python3", "/app/inspection_rules_controller.py"]

# Default arguments
CMD ["--namespace=default", "--output-path=/etc/ironic/inspection_rules.yaml", "--log-level=INFO"]
