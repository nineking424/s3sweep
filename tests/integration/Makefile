.PHONY: help setup start stop test test-e2e test-multiworker test-all clean logs

# Default target
help:
	@echo "s3sweep Integration Test Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  setup          - Start services and setup test data"
	@echo "  start          - Start MinIO and Toxiproxy services"
	@echo "  stop           - Stop all services"
	@echo "  test-e2e       - Run end-to-end tests"
	@echo "  test-multiworker - Run multi-worker tests"
	@echo "  test-all       - Run all tests (with setup/cleanup)"
	@echo "  test           - Run all tests (skip setup if running)"
	@echo "  clean          - Stop services and remove volumes"
	@echo "  logs           - Show service logs"
	@echo "  logs-minio     - Show MinIO logs"
	@echo "  logs-toxiproxy - Show Toxiproxy logs"
	@echo ""
	@echo "Quick start:"
	@echo "  make setup test"

# Start Docker services
start:
	@echo "Starting services..."
	@docker compose up -d || docker-compose up -d

# Setup test environment
setup: start
	@echo "Setting up test environment..."
	@./setup.sh

# Stop services
stop:
	@echo "Stopping services..."
	@docker compose down || docker-compose down

# Run E2E tests
test-e2e:
	@echo "Running E2E tests..."
	@./test_e2e.sh

# Run multi-worker tests
test-multiworker:
	@echo "Running multi-worker tests..."
	@./test_multiworker.sh

# Run all tests (full cycle)
test-all:
	@echo "Running all tests..."
	@./run_all_tests.sh

# Run all tests (skip setup if services running)
test:
	@if curl -sf http://localhost:9000/minio/health/live > /dev/null 2>&1; then \
		SKIP_SETUP=true SKIP_CLEANUP=true ./run_all_tests.sh; \
	else \
		./run_all_tests.sh; \
	fi

# Clean everything
clean:
	@echo "Cleaning up..."
	@docker compose down -v || docker-compose down -v
	@rm -rf testdata/
	@rm -f rclone.conf
	@rm -f *.log

# Show all service logs
logs:
	@docker compose logs -f || docker-compose logs -f

# Show MinIO logs
logs-minio:
	@docker compose logs -f minio || docker-compose logs -f minio

# Show Toxiproxy logs
logs-toxiproxy:
	@docker compose logs -f toxiproxy || docker-compose logs -f toxiproxy

# Check if services are running
status:
	@echo "Service Status:"
	@echo "==============="
	@echo -n "MinIO: "
	@if curl -sf http://localhost:9000/minio/health/live > /dev/null 2>&1; then \
		echo "✓ Running"; \
	else \
		echo "✗ Not running"; \
	fi
	@echo -n "Toxiproxy: "
	@if curl -sf http://localhost:8474/version > /dev/null 2>&1; then \
		echo "✓ Running"; \
	else \
		echo "✗ Not running"; \
	fi
	@echo ""
	@echo "Docker Containers:"
	@docker ps --filter name=s3sweep- --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Quick test (single run, keep environment)
quick:
	@SKIP_CLEANUP=true ./run_all_tests.sh

# Debug mode (verbose output)
debug:
	@bash -x ./run_all_tests.sh

# Verify prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker not found"; exit 1; }
	@command -v rclone >/dev/null 2>&1 || { echo "✗ rclone not found"; exit 1; }
	@command -v mc >/dev/null 2>&1 || { echo "✗ mc (MinIO client) not found"; exit 1; }
	@echo "✓ All prerequisites satisfied"
