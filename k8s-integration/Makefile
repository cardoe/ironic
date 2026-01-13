# Makefile for Ironic InspectionRule CRD and Controller

# Configuration
IMAGE_NAME ?= ironic/inspection-rules-controller
IMAGE_TAG ?= latest
NAMESPACE ?= default
OUTPUT_PATH ?= /etc/ironic/inspection_rules.yaml

.PHONY: help
help:
	@echo "Ironic InspectionRule CRD and Controller"
	@echo ""
	@echo "Available targets:"
	@echo "  install-crd       - Install the InspectionRule CRD"
	@echo "  uninstall-crd     - Uninstall the InspectionRule CRD"
	@echo "  build             - Build the controller Docker image"
	@echo "  push              - Push the controller Docker image"
	@echo "  deploy            - Deploy the controller to Kubernetes"
	@echo "  undeploy          - Remove the controller from Kubernetes"
	@echo "  install-examples  - Install example InspectionRule resources"
	@echo "  delete-examples   - Delete example InspectionRule resources"
	@echo "  logs              - Show controller logs"
	@echo "  test-local        - Run controller locally (requires kubeconfig)"
	@echo "  clean             - Remove temporary files"
	@echo ""
	@echo "Configuration (can be overridden):"
	@echo "  IMAGE_NAME=$(IMAGE_NAME)"
	@echo "  IMAGE_TAG=$(IMAGE_TAG)"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  OUTPUT_PATH=$(OUTPUT_PATH)"

.PHONY: install-crd
install-crd:
	kubectl apply -f inspectionrule-crd.yaml

.PHONY: uninstall-crd
uninstall-crd:
	kubectl delete -f inspectionrule-crd.yaml

.PHONY: build
build:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

.PHONY: push
push: build
	docker push $(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: deploy
deploy:
	kubectl apply -f deployment.yaml

.PHONY: undeploy
undeploy:
	kubectl delete -f deployment.yaml

.PHONY: install-examples
install-examples:
	kubectl apply -f example-inspectionrule.yaml

.PHONY: delete-examples
delete-examples:
	kubectl delete -f example-inspectionrule.yaml

.PHONY: logs
logs:
	kubectl logs -l app=inspection-rules-controller -f

.PHONY: test-local
test-local:
	pip install -q -r requirements.txt
	python3 inspection_rules_controller.py \
		--namespace=$(NAMESPACE) \
		--output-path=/tmp/inspection_rules.yaml \
		--log-level=DEBUG

.PHONY: test-oneshot
test-oneshot:
	pip install -q -r requirements.txt
	python3 inspection_rules_controller.py \
		--one-shot \
		--namespace=$(NAMESPACE) \
		--output-path=/tmp/inspection_rules.yaml \
		--log-level=DEBUG
	@echo ""
	@echo "Generated rules file:"
	@cat /tmp/inspection_rules.yaml

.PHONY: clean
clean:
	rm -f /tmp/inspection_rules.yaml
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete

.PHONY: all
all: build deploy install-examples

.PHONY: setup
setup: install-crd deploy

.PHONY: teardown
teardown: delete-examples undeploy uninstall-crd
